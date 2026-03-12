# Keycloak HA Setup – Architektur

## Übersicht

```
Internet
    │
    ▼
lb01 (Nginx + Certbot)
  :443 TLS-Terminierung
  :80  ACME Challenge
    │
    │ ip_hash Session-Stickiness
    ├──────────────────┐
    ▼                  ▼
kc01 (:8080)      kc02 (:8080)
Keycloak          Keycloak
    │    JGroups TCP :7800    │
    └──────────────────────────┘
    │                  │
    └────────┬──────────┘
             ▼
         db01 (:5432)
         PostgreSQL 16
```

## Komponenten

### lb01 – Load Balancer

- **Nginx**: TLS-Terminierung, Reverse Proxy, ip_hash Session-Stickiness
- **Certbot**: Let's Encrypt ACME-Client, Auto-Renewal via systemd-Timer
- **Fail2ban**: Schutz gegen Brute-Force (SSH + Nginx-Jails)
- **UFW**: Firewall – erlaubt 80/tcp, 443/tcp, SSH

### kc01 / kc02 – Keycloak-Nodes

- **Keycloak 26.5.5**: Quarkus-Distribution, `--optimized` Start nach Build
- **Adoptium Temurin JDK 21**: Bessere Quarkus-Kompatibilität als Debian-Paket
- **JGroups TCP**: Cluster-Datentransport direkt zwischen kc01 und kc02 (Port 7800)
- **JDBC_PING2**: Cluster-Discovery via PostgreSQL (kein Multicast benötigt)
- **UFW**: Erlaubt 8080/tcp von lb01, 9000/tcp von lb01 (Management/Health), 7800/tcp zwischen kc01↔kc02, SSH
- **Fail2ban**: SSH-Schutz

### db01 – Datenbank

- **PostgreSQL 16**: Quell-Repo von postgresql.org (pgdg), nicht Debian-Paket
- **pg_hba.conf**: scram-sha-256 Auth, Zugriff nur von kc01 und kc02
- **UFW**: Erlaubt 5432/tcp nur von KC-Node-IPs, SSH

## Design-Entscheidungen

### JDBC_PING2 statt Multicast

Viele Cloud-/Hosting-Umgebungen blockieren UDP-Multicast. JDBC_PING2 nutzt die bereits vorhandene PostgreSQL-Datenbank für die Node-Discovery – keine zusätzliche Infrastruktur erforderlich.

**Wichtig:** JDBC_PING2 übernimmt nur die Discovery (wer ist im Cluster?). Der eigentliche Cluster-Datenaustausch (Sessions, Caches) läuft über JGroups TCP Port 7800. Bei blockiertem Port 7800 laufen die Nodes isoliert – ohne sichtbaren Fehler, nur mit Log-Warnung.

### TLS-Terminierung am Load Balancer

Keycloak hört intern auf HTTP (:8080). TLS-Terminierung erfolgt am Nginx. Keycloak bekommt via `proxy-headers=xforwarded` die echten Client-IPs und das ursprüngliche HTTPS-Protokoll.

**Warum kein End-to-End TLS?** Vereinfachung: Intern sind alle VMs im selben privaten Netzwerk. Let's Encrypt Zertifikate werden nur an einem Punkt verwaltet.

### ip_hash Session-Stickiness

Keycloak-Sessions sind an einen Node gebunden während einer Auth-Flow-Phase. ip_hash garantiert, dass ein Client immer zum gleichen Backend-Node gelangt.

**Upgrade-Pfad:** Cookie-basiertes Stickiness (`sticky` via Nginx-Modul) ist präziser, erfordert aber zusätzliche Module.

### Proxy-Buffer-Konfiguration

```nginx
proxy_buffer_size   128k;
proxy_buffers       4 256k;
```

Keycloak-JWT-Token mit vielen Realm-Rollen können sehr groß werden. Ohne ausreichende Buffer-Konfiguration liefert Nginx 502-Fehler zurück.

### Keycloak Build-Artefakt

Die Quarkus-Distribution von Keycloak erfordert einen expliziten Build-Schritt (`kc.sh build`), der die Konfiguration in das ausführbare Artefakt kompiliert. Der Service startet dann mit `--optimized` ohne zusätzliche Analysephase.

Der Build-Hash-Mechanismus in `02-setup-keycloak.sh` stellt sicher, dass der Build nur bei tatsächlichen Konfigurationsänderungen ausgeführt wird.

## Skalierung

Das Setup ist auf zwei Keycloak-Nodes ausgelegt. Für weitere Nodes:

1. Neue VM mit `02-setup-keycloak.sh` einrichten
2. Neue Node-IP in `KC_NODE*_IP` Variablen und Nginx-Upstream ergänzen
3. UFW-Regeln auf db01 und bestehenden KC-Nodes anpassen
4. `03-setup-nginx.sh` und `04-harden.sh keycloak` erneut ausführen
