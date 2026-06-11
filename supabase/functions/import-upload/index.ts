// import-upload: receives a Letterboxd export from the static import page
// on a user's computer. The app minted a short-lived transfer code
// (pending_imports row); this function validates it, stores the file in
// the private `imports` bucket under the owner's folder, and marks the
// row ready so the app's poll picks it up.

import { createClient } from "jsr:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "content-type",
};

const MAX_BYTES = 25 * 1024 * 1024;
const CODE_TTL_MINUTES = 30;
const ALLOWED_EXTENSIONS = ["zip", "csv", "txt"];

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "POST only" });

  try {
    // Expired codes also get swept here — the table stays tiny.
    await supabase.from("pending_imports").delete()
      .lt("created_at", new Date(Date.now() - 24 * 3600 * 1000).toISOString());

    const url = new URL(req.url);
    const code = (url.searchParams.get("code") ?? "").toUpperCase().trim();
    const filename = url.searchParams.get("name") ?? "export.zip";
    if (!/^[A-Z2-9]{6}$/.test(code)) {
      return json(400, { error: "That code doesn't look right — check the app." });
    }

    const extension = (filename.split(".").pop() ?? "zip").toLowerCase();
    if (!ALLOWED_EXTENSIONS.includes(extension)) {
      return json(400, { error: "Upload the Letterboxd .zip (or a .csv)." });
    }

    const { data: pending } = await supabase
      .from("pending_imports")
      .select("user_id, status, created_at")
      .eq("code", code)
      .maybeSingle();
    if (!pending) {
      return json(404, { error: "Code not found — generate a fresh one in the app." });
    }
    if (pending.status !== "waiting") {
      return json(409, { error: "This code was already used — generate a fresh one." });
    }
    const ageMinutes = (Date.now() - new Date(pending.created_at).getTime()) / 60000;
    if (ageMinutes > CODE_TTL_MINUTES) {
      return json(410, { error: "Code expired — generate a fresh one in the app." });
    }

    const bytes = new Uint8Array(await req.arrayBuffer());
    if (bytes.length === 0) return json(400, { error: "Empty file." });
    if (bytes.length > MAX_BYTES) {
      return json(413, { error: "File too large — Letterboxd exports are usually under a few MB." });
    }

    const path = `${pending.user_id}/${code}.${extension}`;
    const { error: uploadError } = await supabase.storage
      .from("imports")
      .upload(path, bytes, { contentType: "application/octet-stream", upsert: true });
    if (uploadError) return json(500, { error: "Upload failed — try again." });

    await supabase.from("pending_imports")
      .update({ status: "ready", path })
      .eq("code", code);

    return json(200, { ok: true });
  } catch (e) {
    console.error("import-upload:", e);
    return json(500, { error: "Something went wrong — try again." });
  }
});
