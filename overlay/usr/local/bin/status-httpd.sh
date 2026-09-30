#!/bin/sh
# status-httpd.sh - serve a tiny LAN status page that proxies XMRig's summary.
# Uses busybox httpd + a CGI script so any browser on the LAN can see hashrate.
set -u
RUNDIR="/run/miner"
ENV_FILE="$RUNDIR/miner.env"
WWW="/run/miner/www"
CGI="$WWW/cgi-bin"
HTTP_PORT=8088

MONITOR_PORT=8080
MONITOR_TOKEN="change-me"
WORKER_NAME="rig01"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

mkdir -p "$CGI"

# Static landing page: pulls JSON from the CGI proxy and renders it.
cat > "$WWW/index.html" <<'HTML'
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Miner Status</title>
<style>
 body{font:15px/1.5 system-ui,sans-serif;margin:0;background:#0f1115;color:#e6e6e6}
 .wrap{max-width:640px;margin:0 auto;padding:24px 16px}
 h1{font-size:20px;margin:0 0 16px}
 .card{background:#181b22;border:1px solid #262b36;border-radius:12px;padding:16px;margin:12px 0}
 .k{color:#8b93a7;font-size:13px}.v{font-size:22px;font-weight:600}
 .grid{display:grid;grid-template-columns:1fr 1fr;gap:12px}
 .ok{color:#5bd68a}.bad{color:#ff6b6b}
</style></head><body><div class="wrap">
<h1>⛏️ Miner Status</h1>
<div id="status" class="card">connecting…</div>
<div class="grid">
 <div class="card"><div class="k">Hashrate (10s)</div><div class="v" id="hr">–</div></div>
 <div class="card"><div class="k">Accepted shares</div><div class="v" id="sh">–</div></div>
 <div class="card"><div class="k">Uptime</div><div class="v" id="up">–</div></div>
 <div class="card"><div class="k">Pool</div><div class="v" id="pool" style="font-size:15px">–</div></div>
</div>
<p class="k" id="ts"></p></div>
<script>
function fmtT(s){s=s|0;var h=(s/3600|0),m=((s%3600)/60|0);return h+"h "+m+"m"}
async function tick(){
 try{
  const r=await fetch("/cgi-bin/summary",{cache:"no-store"});
  const d=await r.json();
  const hr=(d.hashrate&&d.hashrate.total&&d.hashrate.total[0])||0;
  document.getElementById("hr").textContent=hr.toFixed(1)+" H/s";
  document.getElementById("sh").textContent=(d.results&&d.results.shares_good)||0;
  document.getElementById("up").textContent=fmtT(d.uptime||0);
  document.getElementById("pool").textContent=(d.connection&&d.connection.pool)||"–";
  const conn=d.connection&&d.connection.uptime>0;
  const s=document.getElementById("status");
  s.innerHTML=conn?'<span class="ok">● mining — pool connected</span>'
                  :'<span class="bad">● not connected to pool</span>';
  document.getElementById("ts").textContent="updated "+new Date().toLocaleTimeString();
 }catch(e){document.getElementById("status").innerHTML='<span class="bad">● miner API unreachable</span>';}
}
tick();setInterval(tick,5000);
</script></body></html>
HTML

# CGI proxy: adds the auth token server-side so the page needs no secret.
cat > "$CGI/summary" <<CGI
#!/bin/sh
echo "Content-Type: application/json"
echo ""
curl -s -m 5 -H "Authorization: Bearer ${MONITOR_TOKEN}" \\
  "http://127.0.0.1:${MONITOR_PORT}/1/summary" || echo '{}'
CGI
chmod +x "$CGI/summary"

exec busybox httpd -f -p "${HTTP_PORT}" -h "$WWW"
