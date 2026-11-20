-- 1 when the phone said the computer of this secret is one of its own ("presence": true on
-- the PUT of the secret). Only such a secret may write a desk-presence lease
-- (PUT /v1/presence) or ask for a push to be held while its person is at a desk
-- (hold_if_desk). Every row that was here before starts at 0, so every helper pushes as
-- before until its phone says otherwise. No index: the column is read with the row of the
-- secret, by its primary key.
ALTER TABLE secrets ADD COLUMN presence INTEGER NOT NULL DEFAULT 0;
