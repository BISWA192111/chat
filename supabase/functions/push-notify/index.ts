/**
 * Ghost Chat — push-notify Edge Function
 * =========================================
 * Works in TWO modes:
 *
 * MODE 1 — Database Webhook (fully server-side, works when app is CLOSED)
 *   Called automatically by a PostgreSQL trigger via pg_net whenever a
 *   new row is inserted into public.messages. Payload shape:
 *   { type: "INSERT", table: "messages", record: { from, text, ts, ... } }
 *   The function looks up the recipient's push_sub from the profiles table.
 *
 * MODE 2 — Direct client call (fallback, used when pg_net is not set up)
 *   Called from sendMessage() in index.html. Payload shape:
 *   { subscription: {...}, title: "...", body: "..." }
 *
 * Setup:
 *   1. npx web-push generate-vapid-keys
 *   2. supabase functions deploy push-notify
 *   3. supabase secrets set VAPID_PUBLIC_KEY=<public>
 *      supabase secrets set VAPID_PRIVATE_KEY=<private>
 *      supabase secrets set VAPID_EMAIL=mailto:you@example.com
 *      supabase secrets set SUPABASE_URL=https://xxxx.supabase.co
 *      supabase secrets set SUPABASE_SERVICE_ROLE_KEY=<service_role_key>
 *   4. In Supabase Dashboard → Database → Webhooks → Create webhook:
 *        Table: messages   Events: INSERT
 *        URL: https://<project>.supabase.co/functions/v1/push-notify
 *        Headers: { Authorization: Bearer <service_role_key> }
 *      OR use the pg_net SQL trigger in supabase_setup.sql (preferred)
 */

import { serve }        from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });

  try {
    const body = await req.json();

    // ── Resolve VAPID keys ──────────────────────────────────────────────
    const VAPID_PUBLIC  = Deno.env.get('VAPID_PUBLIC_KEY')!;
    const VAPID_PRIVATE = Deno.env.get('VAPID_PRIVATE_KEY')!;
    const VAPID_EMAIL   = Deno.env.get('VAPID_EMAIL') || 'mailto:admin@example.com';

    if (!VAPID_PUBLIC || !VAPID_PRIVATE) {
      console.error('VAPID keys not configured');
      return new Response(JSON.stringify({ error: 'VAPID keys missing' }), {
        status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    // ── Detect which mode we're in ───────────────────────────────────────
    let subscription: Record<string, any> | null = null;
    let title = 'Ghost Chat';
    let notifBody = '';

    if (body.type === 'INSERT' && body.table === 'messages' && body.record) {
      // ══ MODE 1: Database Webhook / pg_net trigger ══
      const record    = body.record;
      const sender    = record.from as string;
      const recipient = sender === 'kinny' ? 'cosmic' : 'kinny';
      const msgText   = (record.text as string) || '';

      title     = `${sender.charAt(0).toUpperCase() + sender.slice(1)} • Ghost Chat`;
      notifBody = record.file_url
        ? `📎 ${record.file_name || 'Sent a file'}`
        : (msgText.length > 100 ? msgText.slice(0, 100) + '…' : msgText);

      // Look up recipient's push subscription from the database
      const sbUrl  = Deno.env.get('SUPABASE_URL')!;
      const sbKey  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

      if (!sbUrl || !sbKey) {
        console.error('Supabase credentials not set as secrets');
        return new Response(JSON.stringify({ error: 'Supabase secrets missing' }), {
          status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }

      const supabase = createClient(sbUrl, sbKey);
      const { data: profile, error: profileErr } = await supabase
        .from('profiles')
        .select('push_sub')
        .eq('username', recipient)
        .single();

      if (profileErr || !profile?.push_sub) {
        // Recipient has no push subscription registered — silent skip
        console.log(`No push_sub for ${recipient}, skipping`);
        return new Response(JSON.stringify({ ok: true, skipped: true }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }

      try {
        subscription = JSON.parse(profile.push_sub);
      } catch {
        return new Response(JSON.stringify({ error: 'Invalid push_sub JSON' }), {
          status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }

    } else if (body.subscription) {
      // ══ MODE 2: Direct client call ══
      subscription = body.subscription;
      title        = body.title    || title;
      notifBody    = body.body     || '';

    } else {
      return new Response(JSON.stringify({ error: 'Unrecognised payload' }), {
        status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    // ── Validate subscription ─────────────────────────────────────────────
    if (!subscription?.endpoint) {
      return new Response(JSON.stringify({ error: 'No endpoint in subscription' }), {
        status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    // ── Send the push ─────────────────────────────────────────────────────
    const pushPayload = JSON.stringify({
      title,
      body:    notifBody,
      tag:     'ghost-chat-msg',
      renotify: true,
      url:     '/'
    });

    const webpush = await import('npm:web-push@3.6.7');
    webpush.default.setVapidDetails(VAPID_EMAIL, VAPID_PUBLIC, VAPID_PRIVATE);
    await webpush.default.sendNotification(subscription, pushPayload);

    return new Response(JSON.stringify({ ok: true }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });

  } catch (err: any) {
    // 410 Gone = subscription expired/invalid → log but don't crash
    if (err?.statusCode === 410) {
      console.warn('Push subscription expired (410):', err.endpoint);
      return new Response(JSON.stringify({ ok: true, expired: true }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }
    console.error('Push error:', err);
    return new Response(JSON.stringify({ error: err.message || 'Push failed' }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });
  }
});
