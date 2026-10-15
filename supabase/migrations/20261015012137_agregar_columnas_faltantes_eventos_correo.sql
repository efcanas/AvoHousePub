-- Completa las columnas usadas por avohouse_queue_profile_email.
-- La función ya escribe template_id y variables; el esquema operativo no las tenía.
ALTER TABLE public.avohouse_email_events
  ADD COLUMN IF NOT EXISTS template_id text,
  ADD COLUMN IF NOT EXISTS variables jsonb NOT NULL DEFAULT '{}'::jsonb;
