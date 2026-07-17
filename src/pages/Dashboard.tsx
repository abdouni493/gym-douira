import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { useAuth, usePermissions } from '@/contexts/AuthContext';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { useNavigate } from 'react-router-dom';
import {
  Users, Calendar, DollarSign, Package, AlertTriangle, Truck, Award, Wallet,
  TrendingUp, TrendingDown, Zap, Barcode, ShoppingCart, UserCog,
} from 'lucide-react';
import { supabase, describeError } from '@/lib/supabase';
import { getCaisseBalance } from '@/lib/api/caisse';
import { productStatus } from '@/lib/api/products';
import { formatDZD, cn } from '@/lib/utils';
import { INTERFACES } from '@/lib/permissions';

interface Stats {
  athletes: number;
  activeAthletes: number;
  products: number;
  lowStock: number;
  workers: number;
  suppliers: number;
  pendingPurchases: number;
  freeSessionsToday: number;
  caisseIn: number;
  caisseOut: number;
  caisseBalance: number;
}

/** COUNT(*) with an optional equality filter — head:true fetches no rows. */
const count = async (table: string, eq?: [string, string]): Promise<number> => {
  const base = supabase.from(table).select('*', { count: 'exact', head: true });
  const q = eq ? base.eq(eq[0], eq[1]) : base;
  const { count: c, error } = await q;
  if (error) throw error;
  return c ?? 0;
};

export const Dashboard: React.FC = () => {
  const { user } = useAuth();
  const { canView, isAdmin } = usePermissions();
  const navigate = useNavigate();

  const [stats, setStats] = useState<Stats | null>(null);
  const [error, setError] = useState<string | null>(null);
  const today = new Date().toISOString().split('T')[0];

  const load = useCallback(async () => {
    setError(null);
    try {
      // Stock status is derived, so low-stock needs the rows, not just a count.
      const { data: products, error: pErr } = await supabase
        .from('products').select('current_stock, min_stock_level');
      if (pErr) throw pErr;
      const lowStock = (products ?? []).filter(
        (p) => productStatus(p.current_stock, p.min_stock_level) !== 'in_stock',
      ).length;

      const [athletes, activeAthletes, workers, suppliers, pendingPurchases, freeToday, balance] =
        await Promise.all([
          count('athletes'),
          count('athletes', ['subscription_status', 'active']),
          count('workers'),
          count('suppliers'),
          count('purchase_invoices', ['status', 'pending']),
          count('free_sessions', ['session_date', today]),
          getCaisseBalance().catch(() => ({ total_in: 0, total_out: 0, balance: 0 })),
        ]);

      setStats({
        athletes, activeAthletes,
        products: products?.length ?? 0, lowStock,
        workers, suppliers, pendingPurchases,
        freeSessionsToday: freeToday,
        caisseIn: balance.total_in, caisseOut: balance.total_out, caisseBalance: balance.balance,
      });
    } catch (e) {
      setError(describeError(e));
    }
  }, [today]);

  useEffect(() => { load(); }, [load]);

  // Quick actions only link to interfaces this user can actually open.
  const quickActions = useMemo(() => {
    const all = [
      { key: 'athletes', label: 'Athletes', icon: Users, path: '/athletes', color: 'from-blue-500 to-blue-600' },
      { key: 'pos', label: 'POS', icon: ShoppingCart, path: '/pos', color: 'from-green-500 to-green-600' },
      { key: 'subscriptions', label: 'Subscriptions', icon: Calendar, path: '/subscriptions', color: 'from-purple-500 to-purple-600' },
      { key: 'products', label: 'Stock', icon: Package, path: '/products', color: 'from-orange-500 to-orange-600' },
      { key: 'caisse', label: 'Caisse', icon: Wallet, path: '/caisse', color: 'from-teal-500 to-teal-600' },
      { key: 'scanner', label: 'Scanner', icon: Barcode, path: '/scanner', color: 'from-yellow-500 to-yellow-600' },
      { key: 'workers', label: 'Workers', icon: UserCog, path: '/workers', color: 'from-indigo-500 to-indigo-600' },
    ];
    return all.filter((a) => canView(a.key));
  }, [canView]);

  const cards = useMemo(() => {
    if (!stats) return [];
    const defs = [
      { iface: 'athletes', title: 'Athletes', value: stats.athletes, desc: 'Total members', icon: Users },
      { iface: 'athletes', title: 'Active', value: stats.activeAthletes, desc: 'Active subscriptions', icon: Award },
      { iface: 'products', title: 'Products', value: stats.products, desc: 'In inventory', icon: Package },
      { iface: 'products', title: 'Low stock', value: stats.lowStock, desc: 'Need restocking', icon: AlertTriangle },
      { iface: 'workers', title: 'Workers', value: stats.workers, desc: 'Team members', icon: Users },
      { iface: 'suppliers', title: 'Suppliers', value: stats.suppliers, desc: 'Active suppliers', icon: Truck },
      { iface: 'athletes', title: 'Séances today', value: stats.freeSessionsToday, desc: 'Free sessions', icon: Zap },
      { iface: 'caisse', title: 'In caisse', value: formatDZD(stats.caisseBalance), desc: 'Current balance', icon: Wallet },
    ];
    // Only show a stat if the user can see the interface it comes from.
    return defs.filter((d) => canView(d.iface));
  }, [stats, canView]);

  return (
    <div className="min-h-screen bg-gym-black text-gym-gold p-6">
      <div className="max-w-7xl mx-auto space-y-8">
        {/* Header */}
        <div className="flex items-center justify-between flex-wrap gap-3">
          <div>
            <h1 className="text-4xl font-bold gradient-text mb-2">
              Welcome, {user?.firstName}! 💪
            </h1>
            <p className="text-gym-gold/60 text-lg">Here's your gym at a glance.</p>
          </div>
          <div className="text-right">
            <p className="text-xl font-bold text-gym-gold">
              {new Date().toLocaleDateString('en-US', { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' })}
            </p>
          </div>
        </div>

        {error ? (
          <Card className="bg-gym-gray border-red-500/30">
            <CardContent className="p-8 text-center space-y-3">
              <p className="text-red-400 font-medium">Could not load the dashboard</p>
              <p className="text-sm text-gym-gold/50">{error}</p>
              <Button variant="outline" onClick={load} className="border-gym-gold/30 text-gym-gold hover:bg-gym-gold/10">Try again</Button>
            </CardContent>
          </Card>
        ) : !stats ? (
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
            {[0, 1, 2, 3, 4, 5, 6, 7].map((i) => (
              <Card key={i} className="bg-gym-gray border-gym-gold/20 animate-pulse"><CardContent className="h-28" /></Card>
            ))}
          </div>
        ) : (
          <>
            {/* Stats */}
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
              {cards.map((stat) => {
                const Icon = stat.icon;
                return (
                  <Card key={stat.title} className="bg-gym-gray border-gym-gold/20 hover:border-gym-gold/40 transition-colors">
                    <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                      <CardTitle className="text-sm font-medium text-gym-gold/80">{stat.title}</CardTitle>
                      <div className="p-2 rounded-lg bg-gym-gold/10"><Icon className="h-4 w-4 text-gym-gold" /></div>
                    </CardHeader>
                    <CardContent>
                      <div className="text-3xl font-bold text-gym-gold mb-1">{stat.value}</div>
                      <p className="text-xs text-gym-gold/50">{stat.desc}</p>
                    </CardContent>
                  </Card>
                );
              })}
            </div>

            {/* Cash flow (only if caisse visible) */}
            {canView('caisse') && (
              <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
                <Card className="bg-gym-gray border-gym-gold/20">
                  <CardContent className="p-5 flex items-center gap-3">
                    <div className="w-10 h-10 rounded-lg bg-green-500/15 flex items-center justify-center text-green-400"><TrendingUp className="w-5 h-5" /></div>
                    <div><p className="text-xs text-gym-gold/50">Total in</p><p className="text-lg font-bold text-green-400">{formatDZD(stats.caisseIn)}</p></div>
                  </CardContent>
                </Card>
                <Card className="bg-gym-gray border-gym-gold/20">
                  <CardContent className="p-5 flex items-center gap-3">
                    <div className="w-10 h-10 rounded-lg bg-red-500/15 flex items-center justify-center text-red-400"><TrendingDown className="w-5 h-5" /></div>
                    <div><p className="text-xs text-gym-gold/50">Total out</p><p className="text-lg font-bold text-red-400">{formatDZD(stats.caisseOut)}</p></div>
                  </CardContent>
                </Card>
                <Card className="bg-gym-gray border-gym-gold/20">
                  <CardContent className="p-5 flex items-center gap-3">
                    <div className="w-10 h-10 rounded-lg bg-gym-gold/15 flex items-center justify-center text-gym-gold"><DollarSign className="w-5 h-5" /></div>
                    <div><p className="text-xs text-gym-gold/50">Balance</p><p className="text-lg font-bold text-gym-gold">{formatDZD(stats.caisseBalance)}</p></div>
                  </CardContent>
                </Card>
              </div>
            )}

            {/* Quick actions */}
            {quickActions.length > 0 && (
              <Card className="bg-gym-gray border-gym-gold/20">
                <CardHeader>
                  <CardTitle className="text-gym-gold flex items-center"><Zap className="w-5 h-5 mr-2" />Quick actions</CardTitle>
                  <CardDescription className="text-gym-gold/60">Jump to what you need.</CardDescription>
                </CardHeader>
                <CardContent>
                  <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-3">
                    {quickActions.map((a) => {
                      const Icon = a.icon;
                      return (
                        <Button key={a.key} onClick={() => navigate(a.path)} variant="ghost"
                                className={cn('p-4 h-auto rounded-lg bg-gradient-to-r hover:scale-105 transition-all duration-300 border-0', a.color)}>
                          <div className="flex flex-col items-center space-y-2">
                            <Icon className="w-6 h-6 text-white" />
                            <span className="text-xs text-white font-medium">{a.label}</span>
                          </div>
                        </Button>
                      );
                    })}
                  </div>
                </CardContent>
              </Card>
            )}

            {!isAdmin && cards.length === 0 && quickActions.length === 0 && (
              <Card className="bg-gym-gray border-gym-gold/20">
                <CardContent className="p-12 text-center text-gym-gold/60">
                  Your account has no interfaces granted yet. Ask an administrator to set your permissions.
                </CardContent>
              </Card>
            )}
          </>
        )}
      </div>
    </div>
  );
};
