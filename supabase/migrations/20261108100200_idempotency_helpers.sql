-- Scoped idempotency helpers for backend RPCs.
--
-- The ledger table is owned by the database foundation. These helpers derive
-- scope from trusted caller context, compare request fingerprints, serialize
-- concurrent duplicates with a transaction-scoped advisory lock, and replay the
-- original response.

create or replace function private.idempotency_begin(
  p_scope_type public.idempotency_scope,
  p_scope_id uuid,
  p_operation text,
  p_idempotency_key text,
  p_actor_type public.audit_actor_type,
  p_actor_id uuid,
  p_request_fingerprint text,
  p_expires_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row private.idempotency_keys%rowtype;
  v_id uuid;
begin
  if p_idempotency_key is null
     or length(p_idempotency_key) < 16
     or length(p_idempotency_key) > 128
  then
    perform private.raise_app_error(
      'VALIDATION_ERROR',
      'A valid idempotency key is required'
    );
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      concat_ws(
        '|',
        p_scope_type::text,
        p_scope_id::text,
        p_operation,
        p_idempotency_key
      ),
      0
    )
  );

  select *
    into v_row
    from private.idempotency_keys ik
   where ik.scope_type = p_scope_type
     and ik.scope_id = p_scope_id
     and ik.operation = p_operation
     and ik.idempotency_key = p_idempotency_key
   for update;

  if found then
    if v_row.request_fingerprint <> p_request_fingerprint then
      perform private.raise_app_error(
        'IDEMPOTENCY_CONFLICT',
        'The idempotency key was reused with a different request'
      );
    end if;

    if v_row.status = 'completed' then
      return jsonb_build_object(
        'status', 'replay',
        'response', coalesce(v_row.response_payload, '{}'::jsonb)
      );
    end if;

    if v_row.status = 'pending' then
      perform private.raise_app_error(
        'IDEMPOTENCY_IN_PROGRESS',
        'The idempotent operation is still in progress'
      );
    end if;

    update private.idempotency_keys
       set status = 'pending',
           actor_type = p_actor_type,
           actor_id = p_actor_id,
           request_fingerprint = p_request_fingerprint,
           response_payload = null,
           error_code = null,
           completed_at = null,
           expires_at = p_expires_at
     where id = v_row.id
     returning id into v_id;

    return jsonb_build_object('status', 'new', 'id', v_id);
  end if;

  insert into private.idempotency_keys (
    scope_type,
    scope_id,
    operation,
    idempotency_key,
    actor_type,
    actor_id,
    request_fingerprint,
    status,
    expires_at
  )
  values (
    p_scope_type,
    p_scope_id,
    p_operation,
    p_idempotency_key,
    p_actor_type,
    p_actor_id,
    p_request_fingerprint,
    'pending',
    p_expires_at
  )
  returning id into v_id;

  return jsonb_build_object('status', 'new', 'id', v_id);
end;
$$;

create or replace function private.idempotency_complete(
  p_id uuid,
  p_response jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update private.idempotency_keys
     set status = 'completed',
         response_payload = p_response,
         completed_at = now(),
         error_code = null
   where id = p_id;
end;
$$;

create or replace function private.idempotency_fail(
  p_id uuid,
  p_error_code text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update private.idempotency_keys
     set status = 'failed',
         error_code = p_error_code,
         completed_at = now()
   where id = p_id;
end;
$$;

revoke all on function private.idempotency_begin(
  public.idempotency_scope,
  uuid,
  text,
  text,
  public.audit_actor_type,
  uuid,
  text,
  timestamptz
) from public;
revoke all on function private.idempotency_complete(uuid, jsonb) from public;
revoke all on function private.idempotency_fail(uuid, text) from public;

comment on function private.idempotency_begin(
  public.idempotency_scope,
  uuid,
  text,
  text,
  public.audit_actor_type,
  uuid,
  text,
  timestamptz
) is
  'Begins or replays a scoped idempotent operation. Returns {status:new,id} or {status:replay,response}.';
