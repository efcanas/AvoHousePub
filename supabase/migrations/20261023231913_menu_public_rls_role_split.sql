drop policy if exists menu_sections_select_visible_or_admin on public.menu_sections;
drop policy if exists menu_items_select_visible_or_admin on public.menu_items;

drop policy if exists menu_sections_anon_visible_select on public.menu_sections;
create policy menu_sections_anon_visible_select
  on public.menu_sections for select to anon
  using (visible = true);

drop policy if exists menu_sections_authenticated_visible_or_admin on public.menu_sections;
create policy menu_sections_authenticated_visible_or_admin
  on public.menu_sections for select to authenticated
  using (
    visible = true
    or exists (
      select 1 from public.admin_users a
      where a.user_id = (select auth.uid())
    )
  );

drop policy if exists menu_items_anon_visible_select on public.menu_items;
create policy menu_items_anon_visible_select
  on public.menu_items for select to anon
  using (
    is_active = true
    and exists (
      select 1 from public.menu_sections s
      where s.id = menu_items.section_id and s.visible = true
    )
  );

drop policy if exists menu_items_authenticated_visible_or_admin on public.menu_items;
create policy menu_items_authenticated_visible_or_admin
  on public.menu_items for select to authenticated
  using (
    (
      is_active = true
      and exists (
        select 1 from public.menu_sections s
        where s.id = menu_items.section_id and s.visible = true
      )
    )
    or exists (
      select 1 from public.admin_users a
      where a.user_id = (select auth.uid())
    )
  );
