# Frontend: nginx s ugrađenim statičkim datotekama i predloškom konfiguracije.
FROM nginx:1.27-alpine
# netcat služi testu izolacije (tests/izolacija.sh): iz frontenda se pokušava doći do baze
RUN apk add --no-cache netcat-openbsd \
 && rm -f /etc/nginx/conf.d/default.conf
ENV NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1
COPY default.conf.template /etc/nginx/templates/default.conf.template
COPY static/ /usr/share/nginx/html/
EXPOSE 80
HEALTHCHECK --interval=10s --timeout=3s --retries=3 CMD wget -q -O /dev/null http://127.0.0.1/healthz || exit 1
