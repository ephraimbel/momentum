import fs from 'node:fs/promises';
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
const { PGlite } = await import(pathToFileURL(process.argv[2]).href);
const db = new PGlite();
const athlete = '10000000-0000-0000-0000-000000000001';
try {
  await db.exec(`create role anon; create role authenticated; create role service_role bypassrls;
    create table app_events(user_id uuid, name text, occurred_at timestamptz, params jsonb default '{}');`);
  await db.exec(await fs.readFile(new URL('../../supabase/migrations/20260909000001_adaptive_retention.sql', import.meta.url), 'utf8'));
  await db.exec(await fs.readFile(new URL('../../supabase/migrations/20260909000002_adaptive_cohort_eligibility.sql', import.meta.url), 'utf8'));
  await db.exec(`insert into subscription_events(event_id,event_type,app_user_id,original_transaction_id,environment,period_type,occurred_at,expires_at)
    values('trial','INITIAL_PURCHASE','anonymous','chain','PRODUCTION','TRIAL','2026-09-01','2026-09-04');`);
  await db.query(`insert into app_events values($1,'workout_completed','2026-09-02','{}')`,[athlete]);
  assert.equal((await db.query('select * from adaptive_trial_cohorts')).rows.length,0,'unlinked trial is excluded');
  await db.query(`insert into subscription_events(event_id,event_type,app_user_id,aliases,original_transaction_id,
    environment,period_type,occurred_at,purchased_at,is_trial_conversion)
    values('paid','RENEWAL',$1,array['anonymous'],'chain','PRODUCTION','NORMAL','2026-09-04','2026-09-04',true)`,[athlete]);
  let row=(await db.query('select * from adaptive_trial_cohorts')).rows[0];
  assert.equal(row.completed_during_trial,true); assert.equal(row.converted,true);
  await db.query(`insert into subscription_events(event_id,event_type,app_user_id,original_transaction_id,
    environment,period_type,occurred_at) values('cancel','CANCELLATION','anonymous','chain','SANDBOX','TRIAL','2026-09-03')`);
  row=(await db.query('select * from adaptive_trial_cohorts')).rows[0];
  assert.equal(row.cancelled_during_trial,false,'sandbox cannot contaminate production');
  await db.exec("update subscription_events set environment='PRODUCTION' where event_id='cancel'");
  assert.equal((await db.query('select * from adaptive_trial_cohorts')).rows[0].cancelled_during_trial,true);
  await db.query(`insert into subscription_events(event_id,event_type,app_user_id,environment,period_type,occurred_at,expires_at)
    values('unknown-chain','INITIAL_PURCHASE',$1,'PRODUCTION','TRIAL','2026-09-01','2026-09-04')`,[athlete]);
  const unknown=(await db.query("select * from adaptive_trial_cohorts where event_id='unknown-chain'")).rows[0];
  assert.equal(unknown.has_known_transaction_chain,false,'missing transaction chain must be explicitly excluded from conversion rates');
  const known=(await db.query("select * from adaptive_trial_cohorts where event_id='trial'")).rows[0];
  assert.equal(known.has_known_transaction_chain,true);
  await db.query(`insert into subscription_events(event_id,event_type,app_user_id,environment,period_type,occurred_at,expires_at)
    values('pending','INITIAL_PURCHASE',$1,'PRODUCTION','TRIAL',now(),now()+interval '3 days')`,[athlete]);
  assert.equal((await db.query("select is_mature from adaptive_trial_cohorts where event_id='pending'")).rows[0].is_mature,false);
  await db.exec('set role anon');
  await assert.rejects(db.query('select * from subscription_events'));
  await assert.rejects(db.query('select * from adaptive_trial_cohorts'));
  await db.exec('reset role; set role authenticated');
  await assert.rejects(db.query("insert into subscription_events(event_id,event_type,occurred_at) values('fake','RENEWAL',now())"));
  console.log('PASS: SQL migration, alias linking, real conversion, sandbox isolation, cancellation and access restrictions');
} finally { await db.close(); }
