# Supabase Setup & Integration Guide

## 1. Create the project
1. Go to supabase.com → New Project. Pick a name, a database password (save it), and a region close to your expected users.
2. Wait ~2 minutes for provisioning.
3. Go to **Project Settings → API** and copy your **Project URL** and **anon public key** — you'll need both below.

## 2. Run the schema
1. Open **SQL Editor** in the Supabase dashboard.
2. Paste in the full contents of `supabase-schema.sql` (the file next to this one).
3. Run it. You should see the tables appear under **Table Editor**.

## 3. Install the client library
In your project folder:
```bash
npm install @supabase/supabase-js
```
(If you're keeping this as a single HTML file for now instead of a bundled project, you can instead load it via a script tag: `<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js"></script>`.)

## 4. Initialize the client
Replace the top of the prototype's `<script>` block with:
```javascript
const supabase = window.supabase.createClient(
  'YOUR_PROJECT_URL',
  'YOUR_ANON_KEY'
);
```

## 5. Auth — replace the "what's your name" gate
The prototype currently just asks for a typed name. Real auth means an actual signup/login. Minimal email+password version:
```javascript
async function signUp(email, password, displayName){
  const { data, error } = await supabase.auth.signUp({
    email, password,
    options: { data: { display_name: displayName } }
  });
  if(error) throw error;
  return data.user;
}

async function signIn(email, password){
  const { data, error } = await supabase.auth.signInWithPassword({ email, password });
  if(error) throw error;
  return data.user;
}

function currentUserId(){
  return supabase.auth.getUser().then(r => r.data.user?.id);
}
```

## 6. Couple pairing — replaces the shared-storage-by-default model
```javascript
// Create a couple + get an invite code to share
async function createCouple(){
  const { data, error } = await supabase.from('couples').insert({}).select().single();
  if(error) throw error;
  const userId = await currentUserId();
  await supabase.from('profiles').update({ couple_id: data.id }).eq('id', userId);
  return data.invite_code; // show this to the partner
}

// Partner joins using the code
async function joinCouple(inviteCode){
  const { data, error } = await supabase.from('couples').select('id').eq('invite_code', inviteCode).single();
  if(error) throw error;
  const userId = await currentUserId();
  await supabase.from('profiles').update({ couple_id: data.id }).eq('id', userId);
}
```

## 7. Cycle log — replaces the `periods` local array
```javascript
async function addPeriodRemote(date, symptoms){
  const userId = await currentUserId();
  const { error } = await supabase.from('cycle_logs').insert({ user_id: userId, log_date: date, symptoms });
  if(error) throw error;
}

async function loadPeriodsRemote(){
  const { data, error } = await supabase.from('cycle_logs').select('*').order('log_date', { ascending: false });
  if(error) throw error;
  return data; // same shape your renderLog()/cycleStats() already expect — just map log_date -> date
}

async function deletePeriodRemote(id){
  const { error } = await supabase.from('cycle_logs').delete().eq('id', id);
  if(error) throw error;
}
```

## 8. Shared status — replaces reading the partner's `shared-status` key
Because of the RLS policy in the schema, this query only returns rows if the owner has `share_enabled = true` AND you're in the same couple — enforced by the database, not just the UI:
```javascript
async function loadPartnerLog(partnerUserId){
  const { data, error } = await supabase.from('cycle_logs')
    .select('*').eq('user_id', partnerUserId).order('log_date', { ascending:false });
  if(error) throw error; // empty result if sharing is off — RLS handles it silently
  return data;
}
```
Run your existing `cycleStats()` math client-side on this data, same as today — no need to duplicate the prediction logic server-side yet.

## 9. Checklist items — replaces `checklist` + `custom-checklist-items`
```javascript
async function loadChecklist(coupleId){
  const { data } = await supabase.from('checklist_items').select('*').eq('couple_id', coupleId);
  return data;
}
async function toggleChecklistItem(id, done){
  await supabase.from('checklist_items').update({ done }).eq('id', id);
}
async function addChecklistItemRemote(coupleId, label, userId){
  await supabase.from('checklist_items').insert({ couple_id: coupleId, label, is_custom: true, created_by: userId });
}
```

## 10. Notes — replaces `notes`, covers gestures + Love Notes sends
```javascript
async function loadNotes(coupleId){
  const { data } = await supabase.from('notes').select('*').eq('couple_id', coupleId).order('created_at');
  return data;
}
async function sendNoteRemote(coupleId, authorId, text, isGesture){
  await supabase.from('notes').insert({ couple_id: coupleId, author_id: authorId, text, is_gesture: isGesture });
}
async function reactToNoteRemote(noteId, emoji, currentReactions){
  const updated = { ...currentReactions, [emoji]: (currentReactions[emoji]||0) + 1 };
  await supabase.from('notes').update({ reactions: updated }).eq('id', noteId);
}
```

## 11. Plan / premium status — read-only from the client now
```javascript
async function loadPlan(){
  const userId = await currentUserId();
  const { data } = await supabase.from('profiles').select('plan, plan_cycle').eq('id', userId).single();
  return data.plan; // "free" or "premium" — client can no longer just set this itself
}
```
Note there's no `choosePlan()` client function anymore that sets plan directly — that column is locked to the client by the schema's `revoke update` line. Real upgrades have to go through Google Play Billing → a webhook → the `subscriptions` table → an Edge Function that updates `profiles.plan`. That's the next piece once you're ready for real billing (a small Supabase Edge Function — ask me when you get there).

## 12. What to change in the existing prototype file
- Swap every `safeGet(...)` / `safeSet(...)` call for the matching function above.
- Replace `myName` gate with real `signUp`/`signIn`.
- Replace the automatic shared-storage model with the couple pairing flow (step 6) before any shared screen renders.
- Remove `choosePlan()`'s direct write — leave the UI, but have it call your (future) Play Billing flow instead of writing `plan` directly.

## Realistic next step
This is genuinely enough to get a working backend running locally today. The two things still worth doing before this is "real": (1) wire actual auth UI (currently the prototype has none), and (2) the Play Billing webhook for step 11. Both are good next asks for Claude Code once you're inside your actual project folder — it can read this file, the schema, and the prototype together and do the wiring directly.
