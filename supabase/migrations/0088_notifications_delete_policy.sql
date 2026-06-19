-- Let a recipient delete their own notifications (swipe-to-delete in the bell).
create policy notifications_delete on public.notifications
  for delete using (recipient_id = auth.uid());
