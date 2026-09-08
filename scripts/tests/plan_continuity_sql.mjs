// Run against ephemeral PostgreSQL (PGlite), never the linked production database.
// node scripts/tests/plan_continuity_sql.mjs /path/to/@electric-sql/pglite/dist/index.js
import fs from 'node:fs/promises';
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
const { PGlite } = await import(process.argv[2] ? pathToFileURL(process.argv[2]).href : '@electric-sql/pglite');
const db = new PGlite();
const a = '10000000-0000-0000-0000-000000000001';
const b = '20000000-0000-0000-0000-000000000002';
const ops = [1,2,3,4,5].map(n => `30000000-0000-0000-0000-${String(n).padStart(12,'0')}`);
let passed = 0;
async function test(name, body) { await body(); passed++; console.log(`PASS ${name}`); }
async function as(role, user) {
  await db.exec('reset role');
  await db.query("select set_config('request.jwt.claim.sub', $1, false)", [user ?? '']);
  await db.exec(`set role ${role}`);
}
function snapshot(name) { return { version: 1, profile: {id:a}, coach: {plan:{name}} }; }
async function commit(revision, operation, value) {
  return (await db.query('select public.commit_plan_continuity($1,$2,$3::jsonb) as result',
    [revision, operation, JSON.stringify(value)])).rows[0].result;
}
try {
  await db.exec(`create role anon; create role authenticated;
    create schema auth; create table auth.users(id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;
    grant usage on schema auth to anon, authenticated;
    grant execute on function auth.uid() to anon, authenticated;`);
  await db.query('insert into auth.users values($1),($2)',[a,b]);
  await db.exec(await fs.readFile(new URL('../../supabase/migrations/20260908000001_plan_continuity.sql',import.meta.url),'utf8'));
  await test('anonymous readers and writers are denied', async()=>{
    await as('anon',null);
    await assert.rejects(db.query('select * from public.plan_continuity'));
    await assert.rejects(commit(0,ops[0],snapshot('A')));
  });
  await test('first save creates revision one for authenticated owner', async()=>{
    await as('authenticated',a);
    const row=await commit(0,ops[0],snapshot('A'));
    assert.equal(row.revision,1); assert.equal(row.snapshot.coach.plan.name,'A');
    assert.equal((await db.query('select user_id from public.plan_continuity')).rows[0].user_id,a);
  });
  await test('lost acknowledgement retries are idempotent', async()=>{
    assert.equal((await commit(0,ops[0],snapshot('A'))).revision,1);
  });
  await test('reused operation ID with different payload is rejected', async()=>{
    await assert.rejects(commit(0,ops[0],snapshot('different')), {code:'22023'});
  });
  await test('concurrent stale writer receives winning state without overwriting', async()=>{
    assert.equal((await commit(1,ops[1],snapshot('newer'))).revision,2);
    const stale=await commit(1,ops[2],snapshot('stale'));
    assert.equal(stale.revision,2); assert.equal(stale.snapshot.coach.plan.name,'newer');
    assert.equal(stale.operation_id,ops[1]);
  });
  await test('direct writes cannot bypass compare-and-swap', async()=>{
    await assert.rejects(db.query('update public.plan_continuity set revision=99'));
    await assert.rejects(db.query('delete from public.plan_continuity'));
  });
  await test('another account cannot read or overwrite owner A', async()=>{
    await as('authenticated',b);
    assert.equal((await db.query('select * from public.plan_continuity')).rows.length,0);
    const own=await commit(0,ops[3],snapshot('B'));
    assert.equal(own.revision,1);
    assert.equal((await db.query('select user_id from public.plan_continuity')).rows[0].user_id,b);
    await as('authenticated',a);
    assert.equal((await db.query('select snapshot from public.plan_continuity')).rows[0].snapshot.coach.plan.name,'newer');
  });
  await test('invalid version and negative revision are rejected', async()=>{
    await assert.rejects(commit(-1,ops[4],snapshot('bad')), {code:'22023'});
    await assert.rejects(commit(2,ops[4],{...snapshot('bad'),version:2}), {code:'22023'});
  });
  await test('oversized documents are rejected', async()=>{
    await assert.rejects(commit(2,ops[4],{...snapshot('bad'), extra:'x'.repeat(8*1024*1024)}), {code:'22023'});
  });
  await test('account deletion cascades without affecting another owner', async()=>{
    await as('postgres',null);
    await db.query('delete from auth.users where id=$1',[a]);
    const rows=(await db.query('select user_id from public.plan_continuity')).rows;
    assert.deepEqual(rows.map(x=>x.user_id),[b]);
  });
  console.log(`${passed} PostgreSQL continuity checks passed.`);
} finally { await db.close(); }
