import http.server, json, os, time
VERSION = os.environ.get('APP_VERSION', '1.0.0')
CHART_VERSION = os.environ.get('CHART_VERSION', '?')
IMAGE_TAG = os.environ.get('IMAGE_TAG', '?')
STRATEGY = os.environ.get('DEPLOY_STRATEGY', 'rolling')
POD_NAME = os.environ.get('POD_NAME', 'unknown')
REPLICAS = os.environ.get('REPLICAS', '?')
request_count = 0
start_time = time.time()
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        global request_count
        request_count += 1
        if self.path == '/metrics':
            L = []
            L.append('# HELP http_requests_total Total requests')
            L.append('# TYPE http_requests_total counter')
            L.append('http_requests_total{service="nf-server",version="%s",pod="%s",strategy="%s"} %d' % (VERSION, POD_NAME, STRATEGY, request_count))
            L.append('# HELP up Service up')
            L.append('# TYPE up gauge')
            L.append('up{service="nf-server",version="%s"} 1' % VERSION)
            L.append('# HELP uptime_seconds Uptime')
            L.append('# TYPE uptime_seconds gauge')
            L.append('uptime_seconds{service="nf-server"} %d' % int(time.time()-start_time))
            body = '\n'.join(L) + '\n'
            ct = 'text/plain'
        elif self.path == '/health':
            body = json.dumps({
                "status": "healthy",
                "version": VERSION,
                "chart_version": CHART_VERSION,
                "image": IMAGE_TAG,
                "strategy": STRATEGY,
                "replicas": REPLICAS,
                "pod": POD_NAME,
                "uptime": int(time.time()-start_time),
                "requests": request_count
            })
            ct = 'application/json'
        else:
            body = json.dumps({"service":"nf-server","version":VERSION,"chart_version":CHART_VERSION,"image":IMAGE_TAG,"strategy":STRATEGY,"replicas":REPLICAS,"status":"running"})
            ct = 'application/json'
        self.send_response(200)
        self.send_header('Content-Type', ct)
        self.end_headers()
        self.wfile.write(body.encode())
    def log_message(self, *a): pass
http.server.HTTPServer(('',8000),Handler).serve_forever()
