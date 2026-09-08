// Real embedded PostgreSQL, synthetic rows only; never connects to Supabase.
import { PGlite } from 'npm:@electric-sql/pglite@0.3.14';
const db = new PGlite();
let checks = 0;
const assert = (condition: unknown, message: string) => { checks++; if (!condition) throw new Error(message); };
await db.exec(`create role anon; create role authenticated; create role service_role;
create table app_events (id bigint generated always as identity, install_id uuid not null,
 name text not null, params jsonb not null default '{}', build text default '44',
 occurred_at timestamptz not null, received_at timestamptz not null);`);
await db.exec(await Deno.readTextFile('supabase/migrations/20260907000001_screen_dropoff.sql'));
const install = (n: number) => `00000000-0000-0000-0000-${String(n).padStart(12, '0')}`;
async function event(n: number, name: string, params: object, ageDays: number, build = '44') {
  await db.query(`insert into app_events (install_id,name,params,occurred_at,received_at,build)
    values ($1,$2,$3,now()-$4*interval '1 day',now()-$4*interval '1 day',$5)`, [install(n), name, JSON.stringify(params), ageDays, build]);
}
const screen = (n: number, name: string, seq: string, age: number, session = 'session1') =>
  event(n, 'screen_view', {screen:name, session, seq}, age);
const end = (n: number, reason: string, age: number, duration_s = '60', session = 'session1') =>
  event(n, 'session_end', {last_screen:'WRONG', session, views:'999', duration_s, reason}, age);
await event(1,'app_launched',{first:'true'},10);
await screen(1,'today','1',10);
await screen(1,'plan','2',10);
await screen(1,'plan','2',10); // retry duplicate
await end(1,'background',10);
await end(1,'background',10); // retry end
await screen(1,'fuel','1',9,'session2'); // later unclosed visit; user never returns
await event(2,'app_launched',{first:'true'},10); // no screen: MUST stay in denominator
await screen(3,'today','1',0); // upgraded / current open session: not exit or new acquisition
await event(3,'app_launched',{first:'false'},0,'44');
await event(3,'app_launched',{first:'true'},20,'43');
await screen(4,'settings','1',10);
await end(4,'abandoned',0,'0'); // delayed recovery: no fabricated current-day session/duration
await screen(5,'paywall','999999999999999999999999999999999',10);
await screen(5,'paywall','oops',10);
await end(5,'background',10,'999999999999999999999999999999');
await screen(6,'today','1',10);
await screen(6,'plan','2',10);
await screen(6,'today','3',10);
await end(6,'timed_out',10,'0'); // floor, not measured duration
const rows = async (view: string) => (await db.query<any>(`select * from ${view}`)).rows;
const events = await rows('analytics_screen_events');
assert(events.length === 8, 'duplicates and malformed sequence values must be removed');
const sessions = await rows('analytics_screen_sessions');
assert(sessions.length === 5, 'one session per install/id, including unclosed ones');
assert(sessions.find(s=>s.install_id===install(4)).duration_s === null, 'abandoned duration is unknown');
assert(sessions.find(s=>s.install_id===install(6)).duration_s === null, 'timed-out duration is unknown');
const drop = await rows('session_dropoff');
assert(drop.find(r=>r.last_screen==='plan').sessions === 1, 'end retries must not inflate visits');
assert(!drop.find(r=>r.last_screen==='fuel'), 'unclosed visit is not a confirmed exit');
const exits = await rows('screen_exit_rate');
const today = exits.find(r=>r.screen==='today');
assert(Number(today.exit_pct) === 33.3 && Number(today.session_exit_pct)===50, 'view and visit denominators differ');
const paths = await rows('screen_paths');
assert(paths.some(r=>r.screen==='fuel' && r.next_screen==='(no next screen observed)'), 'open tails must not say ended');
assert(!paths.some(r=>r.screen==='plan' && r.next_screen==='plan'), 'duplicate delivery must not make self transitions');
const churn = await rows('churn_screen');
assert(churn.some(r=>r.last_screen==='fuel'), 'never-returning install must retain its latest unclosed screen');
assert(!churn.some(r=>r.last_screen==='settings'), 'recent actual recovery activity breaks seven-day silence');
const journey = await rows('app_journey');
assert(journey.length===1 && journey[0].installs===2, 'new-install cohort includes pre-screen quits and excludes upgrades');
assert(journey[0].returned_on_later_day===1 && journey[0].returned_d1===1, 'later-day retention is not app-switch count');
const shape = await rows('session_shape');
assert(shape.reduce((n,r)=>n+Number(r.measured_sessions),0)===1, 'only measured background durations enter averages');
for(const role of ['anon','authenticated']) {
 const grants = (await db.query<any>(`select has_table_privilege($1, 'public.churn_screen', 'SELECT') as allowed`, [role])).rows;
 assert(grants[0].allowed === false, `${role} cannot read analytics`);
}
await db.exec(await Deno.readTextFile('scripts/analysis/dashboard_queries.sql'));
const plan = await db.query('explain select * from screen_exit_rate');
console.log(`PASS: migration executed; ${checks} synthetic correctness/privacy checks. EXPLAIN returned ${plan.rows.length} plan nodes.`);
await db.close();
