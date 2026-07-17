import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { Card, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Badge } from '@/components/ui/badge';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import {
  DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuSeparator, DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu';
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from '@/components/ui/alert-dialog';
import {
  Search, Plus, User, Phone, Users, Zap, CalendarCheck, Wallet, Pencil, Trash2,
  MoreVertical, CreditCard, Dumbbell, UserCheck, AlertCircle,
} from 'lucide-react';
import { toast } from '@/hooks/use-toast';
import { formatDZD, cn } from '@/lib/utils';
import { describeError } from '@/lib/supabase';
import { usePermissions } from '@/contexts/AuthContext';
import { Athlete, Sport, listAthletes, listSports, deleteAthlete } from '@/lib/api/athletes';
import { AthleteFormDialog } from '@/components/athletes/AthleteFormDialog';
import { SubscriptionDialog } from '@/components/athletes/SubscriptionDialog';
import { CreditDialog } from '@/components/athletes/CreditDialog';
import { FreeSessionDialog } from '@/components/athletes/FreeSessionDialog';

type DialogKind = 'form' | 'subscription' | 'credit' | 'freeSession' | null;

const isExpired = (iso: string | null): boolean => {
  if (!iso) return true;
  const d = new Date(iso); d.setHours(0, 0, 0, 0);
  const today = new Date(); today.setHours(0, 0, 0, 0);
  return d < today;
};

const StatusBadge: React.FC<{ athlete: Athlete }> = ({ athlete }) => {
  const active = athlete.subscription_status === 'active' && !isExpired(athlete.subscription_expiry);
  return (
    <Badge variant="outline" className={cn('text-[10px] h-5',
      active ? 'border-green-500/40 text-green-400' : 'border-red-500/40 text-red-400')}>
      {active ? 'Active' : 'Expired'}
    </Badge>
  );
};

const Stat: React.FC<{ icon: React.ReactNode; label: string; value: string | number }> = ({ icon, label, value }) => (
  <Card className="bg-gym-gray border-gym-gold/20">
    <CardContent className="p-4 flex items-center gap-3">
      <div className="w-10 h-10 rounded-lg bg-gym-gold/15 flex items-center justify-center text-gym-gold shrink-0">{icon}</div>
      <div className="min-w-0">
        <p className="text-xs text-gym-gold/50">{label}</p>
        <p className="text-lg font-bold text-gym-gold truncate">{value}</p>
      </div>
    </CardContent>
  </Card>
);

export const Athletes: React.FC = () => {
  const { can } = usePermissions();

  const [athletes, setAthletes] = useState<Athlete[]>([]);
  const [sports, setSports] = useState<Sport[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [search, setSearch] = useState('');
  const [statusFilter, setStatusFilter] = useState('all');
  const [sportFilter, setSportFilter] = useState('all');

  const [dialog, setDialog] = useState<DialogKind>(null);
  const [selected, setSelected] = useState<Athlete | null>(null);
  const [toDelete, setToDelete] = useState<Athlete | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const [a, s] = await Promise.all([listAthletes(), listSports()]);
      setAthletes(a);
      setSports(s);
    } catch (e) {
      setError(describeError(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { load(); }, [load]);

  const open = (kind: DialogKind, athlete: Athlete | null) => { setSelected(athlete); setDialog(kind); };
  const close = () => setDialog(null);

  const confirmDelete = async () => {
    if (!toDelete) return;
    try {
      await deleteAthlete(toDelete.id);
      toast({ title: 'Athlete deleted', description: `${toDelete.full_name} removed.` });
      setToDelete(null);
      await load();
    } catch (e) {
      toast({ title: 'Could not delete', description: describeError(e), variant: 'destructive' });
    }
  };

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    return athletes.filter((a) => {
      const matchesSearch = !q || a.full_name.toLowerCase().includes(q)
        || (a.phone ?? '').toLowerCase().includes(q) || (a.email ?? '').toLowerCase().includes(q);
      const active = a.subscription_status === 'active' && !isExpired(a.subscription_expiry);
      const matchesStatus = statusFilter === 'all'
        || (statusFilter === 'active' && active) || (statusFilter === 'expired' && !active);
      const matchesSport = sportFilter === 'all' || a.sport_id === sportFilter;
      return matchesSearch && matchesStatus && matchesSport;
    });
  }, [athletes, search, statusFilter, sportFilter]);

  const stats = useMemo(() => ({
    total: athletes.length,
    active: athletes.filter((a) => a.subscription_status === 'active' && !isExpired(a.subscription_expiry)).length,
    expired: athletes.filter((a) => !(a.subscription_status === 'active' && !isExpired(a.subscription_expiry))).length,
    credit: athletes.reduce((s, a) => s + Number(a.account_balance || 0), 0),
  }), [athletes]);

  const athleteOptions = useMemo(() => athletes.map((a) => ({ id: a.id, full_name: a.full_name })), [athletes]);

  return (
    <div className="min-h-screen bg-gym-black text-gym-gold p-6">
      <div className="max-w-7xl mx-auto space-y-6">
        {/* Header */}
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h1 className="text-3xl font-bold gradient-text">Athletes</h1>
            <p className="text-gym-gold/60 mt-1">Members, subscriptions and free sessions.</p>
          </div>
          <div className="flex flex-wrap gap-2">
            {can('athletes', 'free_session') && (
              <Button variant="outline" onClick={() => open('freeSession', null)}
                      className="border-gym-gold/40 text-gym-gold hover:bg-gym-gold/10">
                <Zap className="w-4 h-4 mr-2" />Séance libre
              </Button>
            )}
            {can('athletes', 'create') && (
              <Button onClick={() => open('form', null)} className="bg-gym-gold text-gym-black hover:bg-gym-gold/90">
                <Plus className="w-4 h-4 mr-2" />New athlete
              </Button>
            )}
          </div>
        </div>

        {/* Stats */}
        <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
          <Stat icon={<Users className="w-5 h-5" />} label="Total" value={stats.total} />
          <Stat icon={<UserCheck className="w-5 h-5" />} label="Active" value={stats.active} />
          <Stat icon={<AlertCircle className="w-5 h-5" />} label="Expired" value={stats.expired} />
          <Stat icon={<Wallet className="w-5 h-5" />} label="Total credit" value={formatDZD(stats.credit)} />
        </div>

        {/* Filters */}
        <Card className="bg-gym-gray border-gym-gold/20">
          <CardContent className="p-4 flex flex-col md:flex-row gap-3">
            <div className="relative flex-1">
              <Search className="absolute left-3 top-1/2 -translate-y-1/2 text-gym-gold/50 w-4 h-4" />
              <Input value={search} onChange={(e) => setSearch(e.target.value)}
                     placeholder="Search by name, phone or email…"
                     className="pl-10 bg-gym-black border-gym-gold/30 text-gym-gold" />
            </div>
            <Select value={statusFilter} onValueChange={setStatusFilter}>
              <SelectTrigger className="w-full md:w-40 bg-gym-black border-gym-gold/30 text-gym-gold">
                <SelectValue placeholder="Status" />
              </SelectTrigger>
              <SelectContent className="bg-gym-gray border-gym-gold/30 text-gym-gold">
                <SelectItem value="all">All statuses</SelectItem>
                <SelectItem value="active">Active</SelectItem>
                <SelectItem value="expired">Expired</SelectItem>
              </SelectContent>
            </Select>
            <Select value={sportFilter} onValueChange={setSportFilter}>
              <SelectTrigger className="w-full md:w-40 bg-gym-black border-gym-gold/30 text-gym-gold">
                <SelectValue placeholder="Sport" />
              </SelectTrigger>
              <SelectContent className="bg-gym-gray border-gym-gold/30 text-gym-gold">
                <SelectItem value="all">All sports</SelectItem>
                {sports.map((s) => <SelectItem key={s.id} value={s.id}>{s.name}</SelectItem>)}
              </SelectContent>
            </Select>
          </CardContent>
        </Card>

        {/* Content */}
        {loading ? (
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4">
            {[0, 1, 2, 3].map((i) => (
              <Card key={i} className="bg-gym-gray border-gym-gold/20 animate-pulse">
                <CardContent className="p-5 h-48" />
              </Card>
            ))}
          </div>
        ) : error ? (
          <Card className="bg-gym-gray border-red-500/30">
            <CardContent className="p-8 text-center space-y-3">
              <p className="text-red-400 font-medium">Could not load athletes</p>
              <p className="text-sm text-gym-gold/50">{error}</p>
              <Button variant="outline" onClick={load}
                      className="border-gym-gold/30 text-gym-gold hover:bg-gym-gold/10">Try again</Button>
            </CardContent>
          </Card>
        ) : filtered.length === 0 ? (
          <Card className="bg-gym-gray border-gym-gold/20">
            <CardContent className="p-12 text-center space-y-2">
              <Users className="w-10 h-10 text-gym-gold/25 mx-auto" />
              <p className="text-gym-gold/60">
                {athletes.length === 0 ? 'No athletes yet.' : 'No athletes match your filters.'}
              </p>
              {athletes.length === 0 && can('athletes', 'create') && (
                <Button onClick={() => open('form', null)} className="gym-button mt-2">
                  <Plus className="w-4 h-4 mr-2" />Add your first athlete
                </Button>
              )}
            </CardContent>
          </Card>
        ) : (
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4">
            {filtered.map((a) => {
              const sportName = sports.find((s) => s.id === a.sport_id)?.name;
              const menu = [
                can('athletes', 'subscribe') && { key: 'subscription', label: 'Subscription', icon: CalendarCheck },
                can('athletes', 'credit') && { key: 'credit', label: 'Add credit', icon: Wallet },
                can('athletes', 'edit') && { key: 'form', label: 'Edit', icon: Pencil },
              ].filter(Boolean) as { key: DialogKind; label: string; icon: React.ComponentType<{ className?: string }> }[];

              return (
                <Card key={a.id} className="bg-gym-gray border-gym-gold/20 hover:border-gym-gold/40 transition-colors overflow-hidden">
                  <CardContent className="p-0">
                    {/* Banner */}
                    <div className="h-16 bg-gradient-to-r from-gym-gold/20 to-gym-gold/5 relative">
                      <div className="absolute -bottom-8 left-4 w-16 h-16 rounded-full ring-4 ring-gym-gray bg-gym-gold/15 flex items-center justify-center overflow-hidden">
                        {a.photo_url
                          ? <img src={a.photo_url} alt="" className="w-full h-full object-cover" />
                          : <User className="w-7 h-7 text-gym-gold/50" />}
                      </div>
                      {(menu.length > 0 || can('athletes', 'delete')) && (
                        <div className="absolute top-2 right-2">
                          <DropdownMenu>
                            <DropdownMenuTrigger asChild>
                              <Button size="icon" variant="ghost"
                                      className="h-7 w-7 text-gym-gold/70 hover:text-gym-gold hover:bg-black/20"
                                      aria-label="Actions">
                                <MoreVertical className="w-4 h-4" />
                              </Button>
                            </DropdownMenuTrigger>
                            <DropdownMenuContent align="end" className="bg-gym-gray border-gym-gold/30 text-gym-gold">
                              {menu.map((m) => (
                                <DropdownMenuItem key={m.key} onClick={() => open(m.key, a)}
                                                  className="cursor-pointer focus:bg-gym-gold/15 focus:text-gym-gold">
                                  <m.icon className="w-4 h-4 mr-2" />{m.label}
                                </DropdownMenuItem>
                              ))}
                              {can('athletes', 'delete') && (
                                <>
                                  <DropdownMenuSeparator className="bg-gym-gold/20" />
                                  <DropdownMenuItem onClick={() => setToDelete(a)}
                                                    className="cursor-pointer text-red-400 focus:bg-red-500/10 focus:text-red-400">
                                    <Trash2 className="w-4 h-4 mr-2" />Delete
                                  </DropdownMenuItem>
                                </>
                              )}
                            </DropdownMenuContent>
                          </DropdownMenu>
                        </div>
                      )}
                    </div>

                    <div className="pt-10 px-4 pb-4 space-y-3">
                      <div className="flex items-start justify-between gap-2">
                        <div className="min-w-0">
                          <h3 className="font-semibold text-gym-gold truncate">{a.full_name}</h3>
                          {sportName && (
                            <span className="inline-flex items-center gap-1 text-xs text-gym-gold/50">
                              <Dumbbell className="w-3 h-3" />{sportName}
                            </span>
                          )}
                        </div>
                        <StatusBadge athlete={a} />
                      </div>

                      <div className="space-y-1 text-xs text-gym-gold/60">
                        <div className="flex items-center gap-2">
                          <Phone className="w-3.5 h-3.5 shrink-0" />
                          <span className="truncate">{a.phone || '—'}</span>
                        </div>
                        {a.subscription_expiry && (
                          <div className="flex items-center gap-2">
                            <CalendarCheck className="w-3.5 h-3.5 shrink-0" />
                            <span>Expires {a.subscription_expiry}</span>
                          </div>
                        )}
                        {a.account_balance > 0 && (
                          <div className="flex items-center gap-2 text-green-400/80">
                            <CreditCard className="w-3.5 h-3.5 shrink-0" />
                            <span>{formatDZD(a.account_balance)} credit</span>
                          </div>
                        )}
                      </div>

                      {can('athletes', 'subscribe') && (
                        <Button size="sm" variant="outline" onClick={() => open('subscription', a)}
                                className="w-full border-gym-gold/30 text-gym-gold hover:bg-gym-gold/10">
                          <CalendarCheck className="w-3.5 h-3.5 mr-1.5" />Subscription
                        </Button>
                      )}
                    </div>
                  </CardContent>
                </Card>
              );
            })}
          </div>
        )}
      </div>

      {/* Dialogs */}
      <AthleteFormDialog isOpen={dialog === 'form'} onClose={close} athlete={selected} onSaved={load} />
      <SubscriptionDialog isOpen={dialog === 'subscription'} onClose={close} athlete={selected} onSaved={load} />
      <CreditDialog isOpen={dialog === 'credit'} onClose={close} athlete={selected} onSaved={load} />
      <FreeSessionDialog isOpen={dialog === 'freeSession'} onClose={close}
                         athletes={athleteOptions} canDelete={can('athletes', 'free_session')} />

      <AlertDialog open={toDelete !== null} onOpenChange={(o) => !o && setToDelete(null)}>
        <AlertDialogContent className="bg-gym-gray border-gym-gold/20 text-gym-gold">
          <AlertDialogHeader>
            <AlertDialogTitle>Delete {toDelete?.full_name}?</AlertDialogTitle>
            <AlertDialogDescription className="text-gym-gold/60">
              This removes the athlete and all their subscriptions, credits and session history.
              This cannot be undone.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel className="bg-transparent border-gym-gold/30 text-gym-gold hover:bg-gym-gold/10">Cancel</AlertDialogCancel>
            <AlertDialogAction onClick={confirmDelete} className="bg-red-600 text-white hover:bg-red-700">Delete</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
};
