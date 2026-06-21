-- Retire the feature-unlock mechanic. The app no longer gates any feature
-- behind referral credits (Average Scores, Social Links, and Stealth Mode are
-- all available to everyone), so these objects are dead. The `referrals`
-- table stays — it still backs the cosmetic referral count.
drop function if exists public.unlock_feature(text);
drop function if exists public.unlocked_features();
drop table if exists public.feature_unlocks;
