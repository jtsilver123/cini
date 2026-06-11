-- Public custom lists are user-generated content too — they need the
-- same report path as notes, comments, and members (Guideline 1.2).
alter table public.reports drop constraint reports_subject_kind_check;
alter table public.reports add constraint reports_subject_kind_check
  check (subject_kind in ('member', 'note', 'comment', 'event', 'list'));
