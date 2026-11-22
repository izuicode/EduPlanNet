// Proxy de IA: la clave de Gemini vive solo aquí (secreto de Cloudflare), nunca en GitHub ni en el navegador.
export default {
  async fetch(req, env) {
    const origins = (env.ALLOWED_ORIGIN || '').split(',').map(x => x.trim());
    const o = req.headers.get('Origin');
    const cors = { 'Access-Control-Allow-Origin': origins.includes(o) ? o : origins[0], 'Access-Control-Allow-Headers': 'Content-Type,Authorization', Vary: 'Origin' };
    if (req.method === 'OPTIONS') return new Response(null, { headers: cors });
    if (req.method !== 'POST' || !origins.includes(o)) return new Response('Forbidden', { status: 403, headers: cors });
    // Solo usuarios con sesión válida de Supabase
    const token = (req.headers.get('Authorization') || '').replace('Bearer ', '');
    const v = await fetch(`${env.SUPABASE_URL}/auth/v1/user`, { headers: { apikey: env.SUPABASE_KEY, Authorization: `Bearer ${token}` } });
    if (!token || !v.ok) return new Response('Unauthorized', { status: 401, headers: cors });
    const b = await req.json().catch(() => ({}));
    const text = String(b.prompt || '').slice(0, 6000);
    const model = /^[\w.-]+$/.test(b.model || '') ? b.model : 'gemini-3.8-flash';
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': env.GEMINI_API_KEY },
      body: JSON.stringify({ contents: [{ parts: [{ text }] }], generationConfig: b.json ? { responseMimeType: 'application/json' } : {} })
    });
    return new Response(r.body, { status: r.status, headers: { ...cors, 'Content-Type': 'application/json' } });
  }
};
