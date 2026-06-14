-- 0045: taste-match rank needs a deterministic tiebreaker.
-- Since 0043 made `position` per-(bucket, media_kind), a loved movie and a
-- loved show can share position 0, so `rank() over (order by bucket, position)`
-- produced ties → noisy Spearman correlation for users who rank both kinds.
-- Add movie_id (unique within a user's rankings) as a stable tiebreaker so
-- each title gets a clean, reproducible rank. Direction is irrelevant to the
-- correlation (both users use the same ordering).
create or replace function public.compute_taste_match(u1 uuid, u2 uuid)
returns numeric language plpgsql stable set search_path to 'public' as $function$
declare
    v_rho numeric;
    v_n integer;
begin
    select corr(a.rk, b.rk), count(*) into v_rho, v_n
    from (select movie_id, rank() over (order by bucket, position, movie_id) as rk
          from rankings where user_id = u1) a
    join (select movie_id, rank() over (order by bucket, position, movie_id) as rk
          from rankings where user_id = u2) b using (movie_id);

    if v_n < 3 or v_rho is null then return null; end if;
    return round((v_rho + 1) / 2 * 100, 2);
end $function$;

-- Recompute with the cleaner ranking.
select public.refresh_taste_matches();
