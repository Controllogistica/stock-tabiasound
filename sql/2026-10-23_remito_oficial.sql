-- Remito oficial (tipo R, con CAI) — NEW GATE SRL
-- Aditivo: no modifica tablas existentes. Los remitos oficiales NO mueven stock.

-- ¿Quién puede crear/editar/emitir remitos oficiales?
create or replace function public.rem_puede()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce((select coalesce(rol_stock,'') in ('admin','jefe_area') or coalesce(puede_facturacion,false)
                   from perfiles where id = auth.uid()), false);
$$;

-- ¿Quién puede administrar los CAI?
create or replace function public.rem_admin()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce((select coalesce(rol_stock,'')='admin' from perfiles where id = auth.uid()), false)
         or public.fac_admin();
$$;

-- CAI cargados (se piden a mano en ARCA, vencen a los ~180 días)
create table if not exists public.rem_cai (
  id uuid primary key default gen_random_uuid(),
  punto_venta integer not null check (punto_venta > 0),
  cai text not null check (cai ~ '^[0-9]{14}$'),
  cai_vto date not null,
  nro_desde bigint not null check (nro_desde > 0),
  nro_hasta bigint not null,
  proximo bigint not null,
  activo boolean not null default true,
  observacion text,
  creado_por uuid default auth.uid(),
  creado_en timestamptz not null default now(),
  check (nro_desde <= nro_hasta),
  check (proximo between nro_desde and nro_hasta + 1)
);

create table if not exists public.rem_oficial (
  id uuid primary key default gen_random_uuid(),
  estado text not null default 'borrador' check (estado in ('borrador','emitido','anulado')),
  fecha date not null default current_date,
  cai_id uuid references public.rem_cai(id),
  punto_venta integer,
  numero bigint,
  cai text,
  cai_vto date,
  cliente_id uuid,
  receptor_nombre text,
  receptor_cuit text,
  receptor_cond_iva text,
  receptor_domicilio text,
  lugar_entrega text,
  origen text,
  transportista text,
  transporte_cuit text,
  patente text,
  orden_compra text,
  observacion text,
  remito_interno_id uuid references public.stock_remitos(id) on delete set null,
  comprobante_id uuid references public.fac_comprobante(id) on delete set null,
  evento_id uuid,
  emitido_en timestamptz,
  emitido_por uuid,
  anulado_en timestamptz,
  anulado_motivo text,
  creado_por uuid default auth.uid(),
  creado_en timestamptz not null default now(),
  unique (punto_venta, numero)
);
create index if not exists rem_oficial_interno_idx on public.rem_oficial(remito_interno_id);
create index if not exists rem_oficial_comp_idx on public.rem_oficial(comprobante_id);

create table if not exists public.rem_oficial_item (
  id uuid primary key default gen_random_uuid(),
  remito_id uuid not null references public.rem_oficial(id) on delete cascade,
  orden integer not null default 0,
  cantidad numeric not null check (cantidad > 0),
  descripcion text not null check (length(trim(descripcion)) > 0),
  codigo text
);
create index if not exists rem_oficial_item_rem_idx on public.rem_oficial_item(remito_id);

-- Un remito emitido o anulado no se puede modificar (solo anular vía RPC)
create or replace function public.rem_oficial_lock()
returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    if old.estado <> 'borrador' then raise exception 'Un remito oficial emitido no se puede borrar; anulalo.'; end if;
    return old;
  end if;
  if old.estado <> 'borrador' and current_setting('rem.rpc', true) is distinct from '1' then
    raise exception 'Un remito oficial emitido no se puede modificar.';
  end if;
  return new;
end $$;
drop trigger if exists rem_oficial_lock_t on public.rem_oficial;
create trigger rem_oficial_lock_t before update or delete on public.rem_oficial
  for each row execute function public.rem_oficial_lock();

create or replace function public.rem_oficial_item_lock()
returns trigger language plpgsql as $$
declare st text;
begin
  select estado into st from rem_oficial where id = coalesce(new.remito_id, old.remito_id);
  if st is not null and st <> 'borrador' then raise exception 'El remito oficial ya fue emitido; sus ítems no se pueden cambiar.'; end if;
  return coalesce(new, old);
end $$;
drop trigger if exists rem_oficial_item_lock_t on public.rem_oficial_item;
create trigger rem_oficial_item_lock_t before insert or update or delete on public.rem_oficial_item
  for each row execute function public.rem_oficial_item_lock();

-- RLS
alter table public.rem_cai enable row level security;
alter table public.rem_oficial enable row level security;
alter table public.rem_oficial_item enable row level security;

drop policy if exists rem_cai_sel on public.rem_cai;
create policy rem_cai_sel on public.rem_cai for select to authenticated using (public.rem_puede());
drop policy if exists rem_cai_admin on public.rem_cai;
create policy rem_cai_admin on public.rem_cai for all to authenticated using (public.rem_admin()) with check (public.rem_admin());

drop policy if exists rem_of_sel on public.rem_oficial;
create policy rem_of_sel on public.rem_oficial for select to authenticated using (true);
drop policy if exists rem_of_ins on public.rem_oficial;
create policy rem_of_ins on public.rem_oficial for insert to authenticated with check (public.rem_puede() and estado = 'borrador');
drop policy if exists rem_of_upd on public.rem_oficial;
create policy rem_of_upd on public.rem_oficial for update to authenticated using (public.rem_puede() and estado = 'borrador') with check (public.rem_puede() and estado = 'borrador');
drop policy if exists rem_of_del on public.rem_oficial;
create policy rem_of_del on public.rem_oficial for delete to authenticated using (public.rem_puede() and estado = 'borrador');

drop policy if exists rem_it_sel on public.rem_oficial_item;
create policy rem_it_sel on public.rem_oficial_item for select to authenticated using (true);
drop policy if exists rem_it_w on public.rem_oficial_item;
create policy rem_it_w on public.rem_oficial_item for all to authenticated using (public.rem_puede()) with check (public.rem_puede());

-- Datos del emisor (NEW GATE) sin exponer certificados de arca_config
create or replace function public.rem_emisor()
returns json language sql stable security definer set search_path to 'public' as $$
  select json_build_object('cuit',cuit,'razon_social',razon_social,'domicilio',domicilio,
    'condicion_iva',condicion_iva,'iibb',iibb,'inicio_actividades',inicio_actividades)
  from arca_config order by id limit 1;
$$;

-- Estado del CAI activo (para avisos en la app)
create or replace function public.rem_cai_estado()
returns json language sql stable security definer set search_path to 'public' as $$
  select coalesce((
    select json_build_object('id',id,'punto_venta',punto_venta,'cai',cai,'cai_vto',cai_vto,
      'proximo',proximo,'nro_hasta',nro_hasta,'restantes',nro_hasta - proximo + 1,
      'dias_vto', cai_vto - current_date)
    from rem_cai where activo and cai_vto >= current_date and proximo <= nro_hasta
    order by cai_vto asc limit 1), null);
$$;

-- Emitir: asigna número correlativo del CAI vigente, de forma atómica
create or replace function public.rem_emitir(p_id uuid)
returns json language plpgsql security definer set search_path to 'public' as $$
declare r rem_oficial; c rem_cai; n bigint; cnt int;
begin
  if not public.rem_puede() then raise exception 'No tenés permiso para emitir remitos oficiales.'; end if;
  select * into r from rem_oficial where id = p_id for update;
  if not found then raise exception 'Remito no encontrado.'; end if;
  if r.estado <> 'borrador' then raise exception 'Este remito ya fue emitido.'; end if;
  if coalesce(trim(r.receptor_nombre),'') = '' then raise exception 'Falta el nombre o razón social del receptor.'; end if;
  if coalesce(trim(r.receptor_cuit),'') = '' then raise exception 'Falta el CUIT del receptor.'; end if;
  if coalesce(trim(r.lugar_entrega),'') = '' then raise exception 'Falta el lugar de entrega.'; end if;
  select count(*) into cnt from rem_oficial_item where remito_id = p_id;
  if cnt = 0 then raise exception 'El remito no tiene ítems.'; end if;
  select * into c from rem_cai where activo and cai_vto >= current_date and proximo <= nro_hasta
    order by cai_vto asc limit 1 for update;
  if not found then raise exception 'No hay un CAI vigente con números disponibles. Cargá uno nuevo en Configuración.'; end if;
  n := c.proximo;
  update rem_cai set proximo = proximo + 1 where id = c.id;
  perform set_config('rem.rpc','1', true);
  update rem_oficial set estado='emitido', cai_id=c.id, punto_venta=c.punto_venta, numero=n,
    cai=c.cai, cai_vto=c.cai_vto, fecha=current_date, emitido_en=now(), emitido_por=auth.uid()
  where id = p_id;
  return json_build_object('punto_venta',c.punto_venta,'numero',n);
end $$;

-- Anular: el número queda consumido, el remito queda registrado como anulado
create or replace function public.rem_anular(p_id uuid, p_motivo text)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.rem_puede() then raise exception 'No tenés permiso.'; end if;
  if coalesce(trim(p_motivo),'') = '' then raise exception 'Indicá el motivo de la anulación.'; end if;
  perform set_config('rem.rpc','1', true);
  update rem_oficial set estado='anulado', anulado_en=now(), anulado_motivo=trim(p_motivo)
   where id = p_id and estado = 'emitido';
  if not found then raise exception 'Solo se pueden anular remitos emitidos.'; end if;
end $$;

revoke all on function public.rem_emitir(uuid) from public, anon;
revoke all on function public.rem_anular(uuid, text) from public, anon;
revoke all on function public.rem_emisor() from public, anon;
revoke all on function public.rem_cai_estado() from public, anon;
grant execute on function public.rem_emitir(uuid), public.rem_anular(uuid,text), public.rem_emisor(), public.rem_cai_estado(), public.rem_puede(), public.rem_admin() to authenticated;
