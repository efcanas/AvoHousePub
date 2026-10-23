create table if not exists public.menu_sections (
  id text primary key,
  title text not null,
  route text not null unique,
  visible boolean not null default true,
  sort_order integer not null default 0,
  price_mode text not null check (price_mode in ('editable', 'embedded')),
  show_names boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.menu_items (
  id text primary key,
  section_id text not null references public.menu_sections(id) on update cascade on delete restrict,
  name text not null,
  image_path text not null,
  price_amount integer,
  display_order integer not null default 0,
  display_group text,
  image_class text not null default '',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint menu_items_price_nonnegative check (price_amount is null or price_amount >= 0),
  constraint menu_items_image_class_valid check (image_class in ('', 'neon-nacional', 'neon-extranjera', 'neon-sin', 'neon-firma'))
);

create index if not exists menu_items_section_order_idx
  on public.menu_items(section_id, display_order);

alter table public.menu_sections enable row level security;
alter table public.menu_items enable row level security;

grant select on public.menu_sections to anon, authenticated;
grant update on public.menu_sections to authenticated;
grant select on public.menu_items to anon, authenticated;
grant update on public.menu_items to authenticated;

drop policy if exists menu_sections_public_visible_select on public.menu_sections;
create policy menu_sections_public_visible_select
  on public.menu_sections for select to anon, authenticated
  using (visible = true);

drop policy if exists menu_sections_admin_select on public.menu_sections;
create policy menu_sections_admin_select
  on public.menu_sections for select to authenticated
  using (exists (
    select 1 from public.admin_users a
    where a.user_id = (select auth.uid())
  ));

drop policy if exists menu_sections_admin_update on public.menu_sections;
create policy menu_sections_admin_update
  on public.menu_sections for update to authenticated
  using (exists (
    select 1 from public.admin_users a
    where a.user_id = (select auth.uid())
  ))
  with check (exists (
    select 1 from public.admin_users a
    where a.user_id = (select auth.uid())
  ));

drop policy if exists menu_items_public_visible_select on public.menu_items;
create policy menu_items_public_visible_select
  on public.menu_items for select to anon, authenticated
  using (
    is_active = true
    and exists (
      select 1 from public.menu_sections s
      where s.id = menu_items.section_id and s.visible = true
    )
  );

drop policy if exists menu_items_admin_select on public.menu_items;
create policy menu_items_admin_select
  on public.menu_items for select to authenticated
  using (exists (
    select 1 from public.admin_users a
    where a.user_id = (select auth.uid())
  ));

drop policy if exists menu_items_admin_update on public.menu_items;
create policy menu_items_admin_update
  on public.menu_items for update to authenticated
  using (exists (
    select 1 from public.admin_users a
    where a.user_id = (select auth.uid())
  ))
  with check (exists (
    select 1 from public.admin_users a
    where a.user_id = (select auth.uid())
  ));

insert into public.menu_sections (id, title, route, visible, sort_order, price_mode, show_names)
values
  ('mezcladitas', 'Mezcladitas', 'mezcladitas.html', true, 1, 'editable', false),
  ('cervezas', 'Cervezas', 'cervezas.html', true, 2, 'embedded', false),
  ('sinalcohol', 'Sin Alcohol', 'sinalcohol.html', true, 3, 'embedded', false),
  ('firma', 'Firma de la Casa', 'firma.html', false, 4, 'editable', true)
on conflict (id) do nothing;

insert into public.menu_items
  (id, section_id, name, image_path, price_amount, display_order, display_group, image_class, is_active)
values
  ('ice-beer','mezcladitas','Ice Beer','legacy:productos/IceBeer.webp',20000,1,null,'',true),
  ('para-el-calor','mezcladitas','Para el Calor','legacy:productos/ParaElCalor.webp',20000,2,null,'',true),
  ('aloha','mezcladitas','Aloha','legacy:productos/Aloha.webp',20000,3,null,'',true),
  ('mexico-azul','mezcladitas','México Azul','legacy:productos/MéxicoAzul.webp',21000,4,null,'',true),
  ('poderosa','mezcladitas','Poderosa','legacy:productos/Poderosa.webp',20000,5,null,'',true),
  ('tropical','mezcladitas','Tropical','legacy:productos/Tropical.webp',20000,6,null,'',true),
  ('gomela','mezcladitas','Gomela','legacy:productos/Gomela.webp',21000,7,null,'',true),
  ('viva-el-divo','mezcladitas','Viva el Divo','legacy:productos/VivaElDivo.webp',21000,8,null,'',true),
  ('mulata','mezcladitas','Mulata','legacy:productos/Mulata.webp',22000,9,null,'',true),
  ('perla-negra','mezcladitas','Perla Negra','legacy:productos/PerlaNegra.webp',22000,10,null,'',true),
  ('dracarys','mezcladitas','Dracarys','legacy:productos/Dracarys.webp',22000,11,null,'',true),
  ('fuego-valyrio','mezcladitas','Fuego Valyrio','legacy:productos/FuegoValyrio.webp',22000,12,null,'',true),

  ('cc-dorada','cervezas','Club Colombia Dorada','legacy:productos/CCDorada.webp',null,1,'NACIONALES','neon-nacional',true),
  ('cc-roja','cervezas','Club Colombia Roja','legacy:productos/CCRoja.webp',null,2,'NACIONALES','neon-nacional',true),
  ('cc-trigo','cervezas','Club Colombia Trigo','legacy:productos/CCTrigo.webp',null,3,'NACIONALES','neon-nacional',true),
  ('cordilleras-rosada','cervezas','3 Cordilleras Rosada','legacy:productos/Rosada.webp',null,4,'NACIONALES','neon-nacional',true),
  ('aguila','cervezas','Águila','legacy:productos/A%CC%81guila.webp',null,5,'NACIONALES','neon-nacional',true),
  ('aguila-light','cervezas','Águila Light','legacy:productos/A%CC%81guila%20Light.webp',null,6,'NACIONALES','neon-nacional',true),
  ('costena','cervezas','Costeña','legacy:productos/Costen%CC%83a.webp',null,7,'NACIONALES','neon-nacional',true),
  ('poker','cervezas','Póker','legacy:productos/Poker.webp',null,8,'NACIONALES','neon-nacional',true),
  ('budweiser','cervezas','Budweiser','legacy:productos/Budweiser.webp',null,9,'EXTRANJERAS','neon-extranjera',true),
  ('corona','cervezas','Corona','legacy:productos/Corona.webp',null,10,'EXTRANJERAS','neon-extranjera',true),
  ('coronita','cervezas','Coronita','legacy:productos/Coronita.webp',null,11,'EXTRANJERAS','neon-extranjera',true),
  ('stella','cervezas','Stella Artois','legacy:productos/Stella.webp',null,12,'EXTRANJERAS','neon-extranjera',true),

  ('soda-amarilla','sinalcohol','Soda Amarilla','legacy:productos/Soda Amarilla.webp',null,1,null,'neon-sin',true),
  ('soda-azul','sinalcohol','Soda Azul','legacy:productos/Soda Azul.webp',null,2,null,'neon-sin',true),
  ('soda-roja','sinalcohol','Soda Roja','legacy:productos/Soda Roja.webp',null,3,null,'neon-sin',true),
  ('agua','sinalcohol','Agua','legacy:productos/Agua.webp',null,4,null,'neon-sin',true),
  ('coca-cola','sinalcohol','Coca-Cola','legacy:productos/Coca-Cola.webp',null,5,null,'neon-sin',true),
  ('electrolit','sinalcohol','Electrolit','legacy:productos/Electrolit.webp',null,6,null,'neon-sin',true),
  ('ginger-ale','sinalcohol','Ginger Ale','legacy:productos/Ginder.webp',null,7,null,'neon-sin',true),
  ('soda','sinalcohol','Soda','legacy:productos/Soda.webp',null,8,null,'neon-sin',true),

  ('corona-dia','firma','Corona Día','legacy:producto.png',18000,1,null,'neon-firma',true),
  ('corona-tarde','firma','Corona Tarde','legacy:producto.png',18000,2,null,'neon-firma',true),
  ('corona-noche','firma','Corona Noche','legacy:producto.png',18000,3,null,'neon-firma',true),
  ('entropia','firma','Entropía','legacy:producto.png',18000,4,null,'neon-firma',true),
  ('explosion-solar','firma','Explosión Solar','legacy:producto.png',18000,5,null,'neon-firma',true),
  ('fusion-naranja','firma','Fusión Naranja','legacy:producto.png',18000,6,null,'neon-firma',true),
  ('gravedad-rosa','firma','Gravedad Rosa','legacy:producto.png',18000,7,null,'neon-firma',true),
  ('el-profe','firma','El Profe','legacy:producto.png',18000,8,null,'neon-firma',true)
on conflict (id) do nothing;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'menu-images',
  'menu-images',
  true,
  8388608,
  array['image/webp','image/jpeg','image/png','image/avif']::text[]
)
on conflict (id) do update
set public = true,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists menu_images_public_read on storage.objects;
create policy menu_images_public_read
  on storage.objects for select to anon, authenticated
  using (bucket_id = 'menu-images');

drop policy if exists menu_images_admin_insert on storage.objects;
create policy menu_images_admin_insert
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'menu-images'
    and exists (
      select 1 from public.admin_users a
      where a.user_id = (select auth.uid())
    )
  );
