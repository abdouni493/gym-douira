// =============================================================================
// create-worker-account  —  Supabase Edge Function
// =============================================================================
// Creates (or updates, or disables) the login account for a worker.
//
// WHY THIS EXISTS
//   Creating an auth user requires the service_role key, which bypasses RLS
//   entirely. That key can never ship inside the React app — anything in the
//   browser bundle is readable by anyone. So the privileged call happens here,
//   server-side, and the app calls this function with the *caller's own* JWT.
//
// SECURITY
//   1. The caller must present a valid JWT (their normal session).
//   2. We verify, using that JWT, that they hold the workers:'account'
//      permission. The check runs through can_do() under RLS, so a worker
//      cannot grant themselves anything.
//   3. Only after that do we use the service_role client to touch auth.
//
// DEPLOY
//   supabase functions deploy create-worker-account --project-ref ubofngegxapjkkygkcht
//
//   SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY are injected
//   automatically by the platform. Do not hardcode them.
// =============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

interface Payload {
  action: 'create' | 'update_password' | 'set_active' | 'delete';
  worker_id: string;
  email?: string;
  password?: string;
  username?: string;
  active?: boolean;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return json({ error: 'Missing Authorization header' }, 401);

    // --- 1. Who is calling? (uses THEIR jwt, so RLS applies) ------------------
    const caller = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: userData, error: userErr } = await caller.auth.getUser();
    if (userErr || !userData.user) return json({ error: 'Invalid session' }, 401);

    // --- 2. Are they allowed to manage worker accounts? -----------------------
    const { data: allowed, error: permErr } = await caller.rpc('can_do', {
      p_interface: 'workers',
      p_action: 'account',
    });
    if (permErr) return json({ error: `Permission check failed: ${permErr.message}` }, 500);
    if (allowed !== true) {
      return json({ error: 'You do not have permission to manage worker accounts.' }, 403);
    }

    const body = (await req.json()) as Payload;
    if (!body?.worker_id) return json({ error: 'worker_id is required' }, 400);

    // --- 3. Privileged work ---------------------------------------------------
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data: worker, error: wErr } = await admin
      .from('workers')
      .select('id, first_name, last_name, user_id')
      .eq('id', body.worker_id)
      .maybeSingle();

    if (wErr) return json({ error: wErr.message }, 500);
    if (!worker) return json({ error: 'Worker not found' }, 404);

    switch (body.action) {
      // ----------------------------------------------------------------------
      case 'create': {
        if (!body.email || !body.password) {
          return json({ error: 'email and password are required' }, 400);
        }
        if (body.password.length < 8) {
          return json({ error: 'Password must be at least 8 characters' }, 400);
        }
        if (worker.user_id) {
          return json({ error: 'This worker already has a login account.' }, 409);
        }

        const { data: created, error: cErr } = await admin.auth.admin.createUser({
          email: body.email.trim().toLowerCase(),
          password: body.password,
          email_confirm: true, // no verification mail; admin vouches for them
          user_metadata: {
            full_name: `${worker.first_name} ${worker.last_name}`,
            worker_id: worker.id,
          },
        });
        if (cErr) return json({ error: cErr.message }, 400);

        const { error: linkErr } = await admin
          .from('workers')
          .update({
            user_id: created.user.id,
            email: body.email.trim().toLowerCase(),
            username: body.username ?? null,
            account_active: true,
          })
          .eq('id', worker.id);

        // Roll back the auth user, or it would be orphaned and its email would
        // be permanently taken with nothing pointing at it.
        if (linkErr) {
          await admin.auth.admin.deleteUser(created.user.id);
          return json({ error: `Could not link account: ${linkErr.message}` }, 500);
        }

        return json({ success: true, user_id: created.user.id });
      }

      // ----------------------------------------------------------------------
      case 'update_password': {
        if (!worker.user_id) return json({ error: 'This worker has no login account.' }, 400);
        if (!body.password || body.password.length < 8) {
          return json({ error: 'Password must be at least 8 characters' }, 400);
        }
        const { error } = await admin.auth.admin.updateUserById(worker.user_id, {
          password: body.password,
        });
        if (error) return json({ error: error.message }, 400);
        return json({ success: true });
      }

      // ----------------------------------------------------------------------
      case 'set_active': {
        if (!worker.user_id) return json({ error: 'This worker has no login account.' }, 400);
        const active = body.active !== false;

        // ban_duration is what actually stops them signing in; account_active
        // alone would only hide it in the UI.
        const { error } = await admin.auth.admin.updateUserById(worker.user_id, {
          ban_duration: active ? 'none' : '876000h', // ~100 years
        });
        if (error) return json({ error: error.message }, 400);

        await admin.from('workers').update({ account_active: active }).eq('id', worker.id);
        return json({ success: true, active });
      }

      // ----------------------------------------------------------------------
      case 'delete': {
        if (!worker.user_id) return json({ error: 'This worker has no login account.' }, 400);
        const { error } = await admin.auth.admin.deleteUser(worker.user_id);
        if (error) return json({ error: error.message }, 400);

        await admin
          .from('workers')
          .update({ user_id: null, account_active: false, username: null })
          .eq('id', worker.id);
        return json({ success: true });
      }

      default:
        return json({ error: `Unknown action: ${body.action}` }, 400);
    }
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
