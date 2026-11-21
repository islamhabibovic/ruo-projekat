"""Backend aplikacije "Bilješke": REST API nad PostgreSQL bazom.

Adresa baze je DNS ime iz zone projekta (DB_HOST, npr. db.projekat.ruo.lab), nikad IP adresa (AO-7).
Lozinka se čita iz datoteke (Docker secret), a ne iz varijable okruženja (AO-9).
"""
import os
import time

import psycopg
from flask import Flask, jsonify, request

DB_HOST = os.environ["DB_HOST"]
DB_NAME = os.environ.get("DB_NAME", "biljeske")
DB_USER = os.environ.get("DB_USER", "biljeske")
DB_PASSWORD_FILE = os.environ.get("DB_PASSWORD_FILE", "/run/secrets/db_password")

app = Flask(__name__)


def _lozinka():
    with open(DB_PASSWORD_FILE, encoding="utf-8") as f:
        return f.read().strip()


def konekcija():
    return psycopg.connect(
        host=DB_HOST, dbname=DB_NAME, user=DB_USER, password=_lozinka(), connect_timeout=3
    )


def inicijalizuj_bazu(pokusaja=30):
    """Pravi tabelu ako ne postoji; čeka bazu jer kontejner može krenuti prije nje."""
    for i in range(pokusaja):
        try:
            with konekcija() as c:
                c.execute(
                    """CREATE TABLE IF NOT EXISTS biljeske (
                           id SERIAL PRIMARY KEY,
                           tekst TEXT NOT NULL CHECK (length(tekst) BETWEEN 1 AND 500),
                           kreirano TIMESTAMPTZ NOT NULL DEFAULT now())"""
                )
            return
        except psycopg.OperationalError:
            if i == pokusaja - 1:
                raise
            time.sleep(2)


@app.get("/api/health")
def health():
    """Zdravlje procesa (koristi HEALTHCHECK); /api/health/db provjerava i bazu."""
    return jsonify(status="ok")


@app.get("/api/health/db")
def health_db():
    try:
        with konekcija() as c:
            c.execute("SELECT 1")
        return jsonify(status="ok", baza=DB_HOST)
    except psycopg.Error as e:
        return jsonify(status="greska", baza=DB_HOST, detalj=str(e).strip()), 503


@app.get("/api/biljeske")
def lista():
    with konekcija() as c:
        redovi = c.execute(
            "SELECT id, tekst, kreirano FROM biljeske ORDER BY id DESC LIMIT 100"
        ).fetchall()
    return jsonify([{"id": r[0], "tekst": r[1], "kreirano": r[2].isoformat()} for r in redovi])


@app.post("/api/biljeske")
def dodaj():
    tekst = ((request.get_json(silent=True) or {}).get("tekst") or "").strip()
    if not 1 <= len(tekst) <= 500:
        return jsonify(greska="tekst mora imati 1 do 500 znakova"), 400
    with konekcija() as c:
        red = c.execute(
            "INSERT INTO biljeske (tekst) VALUES (%s) RETURNING id, kreirano", (tekst,)
        ).fetchone()
    return jsonify(id=red[0], tekst=tekst, kreirano=red[1].isoformat()), 201


@app.delete("/api/biljeske/<int:bid>")
def obrisi(bid):
    with konekcija() as c:
        n = c.execute("DELETE FROM biljeske WHERE id = %s", (bid,)).rowcount
    return ("", 204) if n else (jsonify(greska="ne postoji"), 404)


inicijalizuj_bazu()
