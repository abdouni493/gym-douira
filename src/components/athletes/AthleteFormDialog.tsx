import React, { useEffect, useRef, useState } from 'react';
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { User, Plus, Camera } from 'lucide-react';
import { toast } from '@/hooks/use-toast';
import { describeError } from '@/lib/supabase';
import { uploadImage } from '@/lib/storage';
import {
  Athlete, AthleteInput, Sport, createAthlete, updateAthlete, listSports, createSport,
} from '@/lib/api/athletes';

interface Props {
  isOpen: boolean;
  onClose: () => void;
  athlete: Athlete | null;
  onSaved: () => void;
}

const blank = (): AthleteInput => ({
  first_name: '', last_name: '', email: null, phone: null,
  date_of_birth: null, gender: null, address: null, sport_id: null,
  rfid_uid: null, photo_url: null,
});

export const AthleteFormDialog: React.FC<Props> = ({ isOpen, onClose, athlete, onSaved }) => {
  const isEdit = athlete !== null;
  const [form, setForm] = useState<AthleteInput>(blank());
  const [sports, setSports] = useState<Sport[]>([]);
  const [newSport, setNewSport] = useState('');
  const [preview, setPreview] = useState<string | null>(null);
  const [photoFile, setPhotoFile] = useState<File | null>(null);
  const [saving, setSaving] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);

  const set = <K extends keyof AthleteInput>(k: K, v: AthleteInput[K]) => setForm((f) => ({ ...f, [k]: v }));

  useEffect(() => {
    if (!isOpen) return;
    let active = true;
    (async () => {
      try {
        const s = await listSports();
        if (active) setSports(s);
      } catch (e) {
        toast({ title: 'Could not load sports', description: describeError(e), variant: 'destructive' });
      }
    })();

    if (athlete) {
      setForm({
        first_name: athlete.first_name, last_name: athlete.last_name,
        email: athlete.email, phone: athlete.phone, date_of_birth: athlete.date_of_birth,
        gender: athlete.gender, address: athlete.address, sport_id: athlete.sport_id,
        rfid_uid: athlete.rfid_uid, photo_url: athlete.photo_url,
      });
      setPreview(athlete.photo_url);
    } else {
      setForm(blank());
      setPreview(null);
    }
    setPhotoFile(null);
    setNewSport('');
    return () => { active = false; };
  }, [isOpen, athlete]);

  const onPickPhoto = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    setPhotoFile(file);
    setPreview(URL.createObjectURL(file));
  };

  const addSport = async () => {
    const name = newSport.trim();
    if (!name) return;
    try {
      const s = await createSport(name);
      setSports((prev) => [...prev, s].sort((a, b) => a.name.localeCompare(b.name)));
      set('sport_id', s.id);
      setNewSport('');
    } catch (e) {
      toast({ title: 'Could not add sport', description: describeError(e), variant: 'destructive' });
    }
  };

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.first_name.trim() || !form.last_name.trim()) {
      toast({ title: 'Name required', description: 'First and last name are required.', variant: 'destructive' });
      return;
    }

    setSaving(true);
    try {
      let photoUrl = form.photo_url ?? null;
      if (photoFile) {
        photoUrl = await uploadImage('athlete-photos', photoFile);
      }
      const payload: AthleteInput = { ...form, photo_url: photoUrl };

      if (isEdit && athlete) {
        await updateAthlete(athlete.id, payload);
        toast({ title: 'Athlete updated', description: `${form.first_name} ${form.last_name} saved.` });
      } else {
        await createAthlete(payload);
        toast({ title: 'Athlete added', description: `${form.first_name} ${form.last_name} created.` });
      }
      onSaved();
      onClose();
    } catch (e) {
      toast({ title: 'Could not save athlete', description: describeError(e), variant: 'destructive' });
    } finally {
      setSaving(false);
    }
  };

  return (
    <Dialog open={isOpen} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="bg-gym-gray border-gym-gold/20 text-gym-gold max-w-xl max-h-[92vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle className="gradient-text">{isEdit ? 'Edit athlete' : 'New athlete'}</DialogTitle>
          <DialogDescription className="text-gym-gold/60">
            {isEdit ? 'Update this athlete’s profile.' : 'Add a new member.'}
          </DialogDescription>
        </DialogHeader>

        <form onSubmit={submit} className="space-y-4">
          {/* Photo */}
          <div className="flex items-center gap-4">
            <button type="button" onClick={() => fileRef.current?.click()}
                    className="relative w-20 h-20 rounded-full bg-gym-gold/15 flex items-center justify-center overflow-hidden group shrink-0">
              {preview
                ? <img src={preview} alt="" className="w-full h-full object-cover" />
                : <User className="w-8 h-8 text-gym-gold/50" />}
              <span className="absolute inset-0 bg-black/50 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
                <Camera className="w-5 h-5 text-white" />
              </span>
            </button>
            <div className="text-xs text-gym-gold/50">
              <p>Click to {preview ? 'change' : 'add'} a photo.</p>
              <p>Stored in the athlete-photos bucket.</p>
            </div>
            <input ref={fileRef} type="file" accept="image/*" onChange={onPickPhoto} className="hidden" />
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label>First name *</Label>
              <Input value={form.first_name} onChange={(e) => set('first_name', e.target.value)} className="gym-input" />
            </div>
            <div className="space-y-1.5">
              <Label>Last name *</Label>
              <Input value={form.last_name} onChange={(e) => set('last_name', e.target.value)} className="gym-input" />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label>Phone</Label>
              <Input value={form.phone ?? ''} onChange={(e) => set('phone', e.target.value)} className="gym-input" />
            </div>
            <div className="space-y-1.5">
              <Label>Email</Label>
              <Input type="email" value={form.email ?? ''} onChange={(e) => set('email', e.target.value)} className="gym-input" />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label>Date of birth</Label>
              <Input type="date" value={form.date_of_birth ?? ''}
                     onChange={(e) => set('date_of_birth', e.target.value || null)} className="gym-input" />
            </div>
            <div className="space-y-1.5">
              <Label>Gender</Label>
              <Select value={form.gender ?? undefined} onValueChange={(v) => set('gender', v)}>
                <SelectTrigger className="gym-input"><SelectValue placeholder="Select" /></SelectTrigger>
                <SelectContent className="bg-gym-gray border-gym-gold/30 text-gym-gold">
                  <SelectItem value="male">Male</SelectItem>
                  <SelectItem value="female">Female</SelectItem>
                </SelectContent>
              </Select>
            </div>
          </div>

          <div className="space-y-1.5">
            <Label>Sport</Label>
            <Select value={form.sport_id ?? undefined} onValueChange={(v) => set('sport_id', v)}>
              <SelectTrigger className="gym-input"><SelectValue placeholder="Select a sport" /></SelectTrigger>
              <SelectContent className="bg-gym-gray border-gym-gold/30 text-gym-gold">
                {sports.map((s) => <SelectItem key={s.id} value={s.id}>{s.name}</SelectItem>)}
              </SelectContent>
            </Select>
            <div className="flex gap-2">
              <Input value={newSport} onChange={(e) => setNewSport(e.target.value)}
                     placeholder="Create a new sport…" className="gym-input"
                     onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); addSport(); } }} />
              <Button type="button" variant="outline" onClick={addSport} disabled={!newSport.trim()}
                      className="border-gym-gold/40 text-gym-gold hover:bg-gym-gold/10 shrink-0">
                <Plus className="w-4 h-4" />
              </Button>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label>RFID card UID</Label>
              <Input value={form.rfid_uid ?? ''} onChange={(e) => set('rfid_uid', e.target.value)}
                     className="gym-input font-mono" placeholder="A3F2C1D4" />
            </div>
            <div className="space-y-1.5">
              <Label>Address</Label>
              <Input value={form.address ?? ''} onChange={(e) => set('address', e.target.value)} className="gym-input" />
            </div>
          </div>

          <DialogFooter className="gap-2">
            <Button type="button" variant="ghost" onClick={onClose} disabled={saving}>Cancel</Button>
            <Button type="submit" className="gym-button" disabled={saving}>
              {saving ? 'Saving…' : isEdit ? 'Save changes' : 'Add athlete'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
};
