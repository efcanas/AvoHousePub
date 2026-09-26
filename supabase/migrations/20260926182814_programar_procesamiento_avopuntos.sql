do $$
declare
  v_jobid bigint;
begin
  select jobid into v_jobid
  from cron.job
  where jobname = 'avohouse_avopuntos_process'
  limit 1;

  if v_jobid is not null then
    perform cron.unschedule(v_jobid);
  end if;
end
$$;

select cron.schedule(
  'avohouse_avopuntos_process',
  '*/5 * * * *',
  $cron$
    select net.http_post(
      url := 'https://tjarildqqxtjmafpiyuz.supabase.co/functions/v1/avopuntos-process-receipts',
      body := '{"mode":"process"}'::jsonb,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-avohouse-loyverse-webhook-secret',
        (
          select decrypted_secret
          from vault.decrypted_secrets
          where name = 'avohouse_loyverse_webhook_secret'
          limit 1
        )
      ),
      timeout_milliseconds := 5000
    );
  $cron$
);