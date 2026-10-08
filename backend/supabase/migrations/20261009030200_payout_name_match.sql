-- Blueprint 05 — B2/B3: bank-name vs NIN-name rule (Q1-C, version nm-1), the NIN
-- plug-in point (U-02), re-checks and withdrawal eligibility (Q4-B, Q6-B).

create function payout.name_rule_version()
returns text
language sql
immutable
set search_path = ''
as $$ select 'nm-1' $$;

-- Words of a name: NFKD, combining marks dropped, uppercase; `.`, `'` and `’`
-- deleted; any other non A–Z character splits words.
create function payout.name_words(p_name text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    array_remove(
      regexp_split_to_array(
        btrim(regexp_replace(
          translate(
            upper(regexp_replace(
              normalize(coalesce(p_name, ''), NFKD),
              '[̀-ͯ᪰-᫿᷀-᷿⃐-⃿︠-︯]', '', 'g'
            )),
            '.''’', ''
          ),
          '[^A-Z]+', ' ', 'g'
        )),
        ' '
      ),
      ''
    ),
    '{}'::text[]
  );
$$;

-- Leading title words on the bank side (Q1-C).
create function payout.strip_titles(p_words text[])
returns text[]
language plpgsql
immutable
set search_path = ''
as $$
declare
  words text[] := p_words;
begin
  while cardinality(words) > 0 and words[1] = any (array[
    'MR', 'MRS', 'MS', 'MISS', 'DR', 'CHIEF', 'ALHAJI', 'ALHAJA', 'PASTOR', 'PROF', 'ENGR', 'BARR', 'HRH'
  ]) loop
    words := words[2:];
  end loop;
  return words;
end;
$$;

-- Q1-C. p_legal is { given, middle: [..], surname } from the NIN record, or
-- null while no identity is verified (→ identity_pending).
--   required: every surname word and the first given-name word, in full;
--   optional: other given-name words and middle names, in full or as an initial;
--   every bank word is used by a different NIN word; at least two bank words.
create function payout.name_match(p_legal jsonb, p_bank_name text)
returns payout.name_match_result
language plpgsql
immutable
set search_path = ''
as $$
declare
  given text[];
  required text[];
  optional text[];
  bank text[];
  word text;
  i int;
  found_at int;
begin
  if p_legal is null or jsonb_typeof(p_legal) = 'null' then
    return 'identity_pending'::payout.name_match_result;
  end if;
  if jsonb_typeof(p_legal) <> 'object' or jsonb_typeof(p_legal->'given') <> 'string'
    or jsonb_typeof(p_legal->'surname') <> 'string'
    or coalesce(jsonb_typeof(p_legal->'middle'), 'array') not in ('array', 'null')
  then
    raise exception using errcode = 'P0001', message = 'invariant_violation', detail = '{"field": "legal_name"}';
  end if;

  given := payout.name_words(p_legal->>'given');
  required := payout.name_words(p_legal->>'surname');
  if cardinality(given) = 0 or cardinality(required) = 0 then
    raise exception using errcode = 'P0001', message = 'invariant_violation', detail = '{"field": "legal_name"}';
  end if;
  required := required || given[1];
  optional := given[2:] || coalesce((
    select array_agg(w.part order by m.pos, w.pos)
    from jsonb_array_elements_text(case when jsonb_typeof(p_legal->'middle') = 'array'
      then p_legal->'middle' else '[]'::jsonb end) with ordinality as m (middle_name, pos)
    cross join lateral unnest(payout.name_words(m.middle_name)) with ordinality as w (part, pos)
  ), '{}'::text[]);

  bank := payout.strip_titles(payout.name_words(p_bank_name));
  if cardinality(bank) < 2 then
    return 'mismatched'::payout.name_match_result;
  end if;

  -- Required words, in full.
  foreach word in array required loop
    found_at := array_position(bank, word);
    if found_at is null then
      return 'mismatched'::payout.name_match_result;
    end if;
    bank := bank[:found_at - 1] || bank[found_at + 1:];
  end loop;

  -- Remaining full words use an equal optional word.
  i := 1;
  while i <= cardinality(bank) loop
    if length(bank[i]) > 1 then
      found_at := array_position(optional, bank[i]);
      if found_at is null then
        return 'mismatched'::payout.name_match_result;
      end if;
      optional := optional[:found_at - 1] || optional[found_at + 1:];
      bank := bank[:i - 1] || bank[i + 1:];
    else
      i := i + 1;
    end if;
  end loop;

  -- Single letters use the initial of a remaining optional word.
  foreach word in array bank loop
    found_at := null;
    i := 1;
    while found_at is null and i <= cardinality(optional) loop
      if left(optional[i], 1) = word then
        found_at := i;
      end if;
      i := i + 1;
    end loop;
    if found_at is null then
      return 'mismatched'::payout.name_match_result;
    end if;
    optional := optional[:found_at - 1] || optional[found_at + 1:];
  end loop;

  return 'matched'::payout.name_match_result;
end;
$$;

-- NIN plug-in point (U-02). Returns null until a NIN slice exists. That slice
-- replaces this function (same signature) to return
-- { "given", "middle": [..], "surname", "verifiedAt" } and calls
-- payout.recheck_name_match in the transaction that locks the legal name.
create function identity.legal_name(p_user_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select case when p_user_id is null then null::jsonb end;
$$;

-- ── Owner alerts ──────────────────────────────────────────────────────────

-- Every owner alert goes through here. Placeholder until slice 03's outbox is
-- on main; 20261009030400 replaces the body with outbox.enqueue_email.
create function payout.alert_owner(p_account payout.accounts, p_action text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_action not in ('added', 'replaced', 'deactivated', 'primary_changed', 'name_mismatch') then
    perform identity.fail('invariant_violation', jsonb_build_object('field', 'action'));
  end if;
  if p_account.id is null then
    perform identity.fail('invariant_violation', jsonb_build_object('field', 'account'));
  end if;
end;
$$;

-- Safe audit fields: never digits beyond the last 4, names or ciphertext.
create function payout.audit_fields(p_account payout.accounts)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'payoutAccountId', p_account.id,
    'bankCode', p_account.bank_code,
    'last4', p_account.account_last4,
    'status', p_account.status,
    'nameMatch', p_account.name_match,
    'isPrimary', p_account.is_primary
  );
$$;

-- Re-runs the name rule for every active account of a person, e.g. when the
-- NIN slice locks their legal name. A failing account loses primary and its
-- owner is alerted. Returns how many results changed.
create function payout.recheck_name_match(p_user_id uuid)
returns int
language plpgsql
set search_path = ''
as $$
declare
  legal jsonb;
  previous payout.accounts;
  account payout.accounts;
  result payout.name_match_result;
  changed int := 0;
begin
  perform payout.lock_owner(p_user_id);
  legal := identity.legal_name(p_user_id);

  for previous in
    select * from payout.accounts
    where owner_user_id = p_user_id and status = 'active'
    order by id
    for update
  loop
    result := payout.name_match(legal, previous.account_name);
    update payout.accounts
    set name_match = result,
        name_rule_version = payout.name_rule_version(),
        name_checked_at = now(),
        is_primary = is_primary and result <> 'mismatched'
    where id = previous.id
    returning * into account;

    if result <> previous.name_match then
      changed := changed + 1;
      if result = 'mismatched' then
        perform audit.record('payout_account.name_mismatch', null, null, p_user_id,
          p_safe_before => payout.audit_fields(previous), p_safe_after => payout.audit_fields(account));
        perform payout.alert_owner(account, 'name_mismatch');
      end if;
    end if;
  end loop;
  return changed;
end;
$$;

-- Withdrawal eligibility (W-09, Q4-B, Q6-B). Call under the withdrawal's lock
-- order, before ledger locks; holds the account row FOR SHARE.
create function payout.eligible_destination(p_owner_user_id uuid, p_payout_account_id uuid)
returns payout.accounts
language plpgsql
set search_path = ''
as $$
declare
  account payout.accounts;
begin
  select * into account from payout.accounts
  where id = p_payout_account_id and owner_user_id = p_owner_user_id
  for share;
  if account.id is null then
    perform identity.fail('not_found');
  end if;
  if account.status <> 'active' then
    perform identity.fail('payout_account_unusable', jsonb_build_object('reason', 'inactive'));
  end if;
  if account.verification_status <> 'verified' then
    perform identity.fail('payout_account_unusable', jsonb_build_object('reason', 'unverified'));
  end if;
  if account.name_match = 'mismatched' then
    perform identity.fail('payout_account_unusable', jsonb_build_object('reason', 'name_mismatch'));
  end if;
  if now() < account.usable_from then
    perform identity.fail('payout_account_unusable',
      jsonb_build_object('reason', 'cooling_off', 'usableFrom', account.usable_from));
  end if;
  return account;
end;
$$;
