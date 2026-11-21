# Backend: multi-stage build (DO-5). Faza 1 instalira zavisnosti, finalna slika nema pip keš ni alate za build.
FROM python:3.12-slim AS build
WORKDIR /w
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim
RUN useradd --system --uid 10001 app
WORKDIR /app
COPY --from=build /install /usr/local
COPY app.py .
USER app
EXPOSE 8000
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD python -c "import urllib.request as u; u.urlopen('http://127.0.0.1:8000/api/health', timeout=2)"
# 2 workera su dovoljna za lab; --preload: inicijalizacija baze jednom, prije forka
CMD ["gunicorn", "--preload", "-w", "2", "-b", "0.0.0.0:8000", "--access-logfile", "-", "app:app"]
