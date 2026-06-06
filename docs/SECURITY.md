# Plan de Hardening de Seguridad — Setup AWS y Local

**Documento:** SECURITY — Tareas de hardening identificadas durante el desarrollo
**Proyecto:** LLM Data Engineering Pipeline (Proyecto 12 — BSG Institute)
**Versión:** 1.0
**Fecha:** 2026-05-24
**Estado:** Tareas abiertas — bajo seguimiento del autor

---

## Resumen ejecutivo

Durante la fase de setup del IaC se identificaron **tres riesgos de seguridad** en el entorno local del autor que no son bloqueantes para el desarrollo académico pero **deben mitigarse antes de cualquier uso productivo o demostración pública**. Este documento los registra con su mitigación recomendada y prioridad. Cada riesgo se resuelve en menos de 30 minutos.

---

## Riesgo 1 — Uso de cuenta AWS root para operación 🚨 CRÍTICO

### Hallazgo
La identidad AWS configurada al momento del setup era:
```
Arn: arn:aws:iam::275541169383:root
```

El usuario root tiene acceso ilimitado a la cuenta AWS, incluyendo:
- Modificación de configuración de billing y métodos de pago
- Cierre de la cuenta AWS
- Modificación o eliminación de cualquier recurso o política
- Acceso a credenciales de IAM users hijos
- Acceso a soporte premium y casos abiertos

Si las credenciales root se filtran (por ejemplo, en un `terraform.tfstate` accidentalmente commiteado, en logs de CloudTrail expuestos, o en clipboard history), el atacante obtiene control total e irrevocable de la cuenta — y el costo asociado a "spin-up" malicioso de recursos (cripto mining, fraude) puede llegar a decenas de miles de dólares antes de detectarse.

### Mitigación recomendada

| Paso | Acción | Tiempo |
|---|---|---|
| 1 | Crear IAM User `bsg-acmeco-rag-admin` con grupo `Admins` (política `AdministratorAccess`) | 5 min |
| 2 | Generar access key + secret key para ese user | 1 min |
| 3 | Configurar `aws configure` localmente con esas credenciales | 2 min |
| 4 | Activar MFA en el IAM user (Google Authenticator, Authy o YubiKey) | 5 min |
| 5 | Activar MFA en el usuario root | 5 min |
| 6 | Guardar credenciales root en gestor de contraseñas (1Password, Bitwarden) — no en archivo plano | 2 min |
| 7 | Cerrar sesión de root en consola y verificar acceso con IAM user | 2 min |

### Pasos detallados con AWS CLI

```powershell
# Requiere estar logueado como root la primera vez
aws iam create-group --group-name Admins
aws iam attach-group-policy --group-name Admins --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam create-user --user-name bsg-acmeco-rag-admin
aws iam add-user-to-group --user-name bsg-acmeco-rag-admin --group-name Admins
aws iam create-access-key --user-name bsg-acmeco-rag-admin

# La salida incluye AccessKeyId y SecretAccessKey — guardarlos UNA vez
# Luego reconfigurar
aws configure
# AWS Access Key ID: <pegar AccessKeyId nuevo>
# AWS Secret Access Key: <pegar SecretAccessKey nuevo>
# Default region: us-east-1
# Default output: json

# Verificar
aws sts get-caller-identity
# Arn debe terminar en :user/bsg-acmeco-rag-admin (NO :root)
```

### Mejora adicional (Fase 1.1)

Crear roles separados por tarea con permisos mínimos en vez de `AdministratorAccess`:
- `bsg-acmeco-rag-terraform` — sólo lo necesario para crear/modificar los recursos del IaC
- `bsg-acmeco-rag-readonly` — para revisar el estado sin modificar
- `bsg-acmeco-rag-billing` — sólo billing y cost explorer

### Prioridad: **ALTA — antes del primer `terraform apply` real**

---

## Riesgo 2 — Falla de verificación SSL (SSL inspection corporativo) ⚠️ MEDIO

### Hallazgo
Al ejecutar `aws sts get-caller-identity` el CLI devuelve:
```
SSL validation failed for https://sts.us-east-1.amazonaws.com/
[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed:
unable to get local issuer certificate
```

El comando funciona con `--no-verify-ssl` pero esa bandera **desactiva la verificación de cadena de certificados** — un atacante en posición Man-in-the-Middle (MitM) podría suplantar `sts.us-east-1.amazonaws.com` sin que el CLI lo detecte.

El mismo síntoma apareció al intentar `winget install` (Microsoft Store source falla con `0x8a15005e: The server certificate did not match any of the expected values`).

### Causa probable
La red del autor inspecciona tráfico SSL (típico de Windows corporativo con ZScaler, Netskope, Symantec WSS, Cisco Umbrella, o similar). Estos productos terminan la conexión TLS en el cliente, instalan un certificado raíz custom en el almacén de Windows, y re-cifran hacia el servidor real. Python (que es la base del AWS CLI v2) y winget no usan por defecto el almacén de Windows, sino sus propios bundles de certificados.

### Mitigación recomendada

**Opción A — Apuntar AWS CLI al CA bundle del sistema (preferido):**

```powershell
# 1. Pedir a IT el bundle corporativo (.pem) o exportar del Windows cert store
# Ruta típica: \\corp-share\IT\certs\corporate-ca-bundle.pem

# 2. Configurar AWS CLI permanentemente
[System.Environment]::SetEnvironmentVariable(
  "AWS_CA_BUNDLE",
  "C:\path\to\corporate-ca-bundle.pem",
  "User"
)

# 3. Verificar (cerrar y reabrir terminal)
aws sts get-caller-identity   # sin --no-verify-ssl
```

**Opción B — Bypass temporal (NO recomendada para uso recurrente):**

```powershell
# Sólo para comandos puntuales
aws <cmd> --no-verify-ssl
```

### Impacto del problema

| Acción | Funciona sin fix |
|---|---|
| `terraform init/plan/apply` | Probable fallo igual que AWS CLI |
| Boto3 desde Python (Lambda local test) | Mismo problema |
| `aws s3 cp` | Mismo problema |
| AWS Console en navegador | Sí (Windows cert store) |
| `winget install` desde msstore | Falla, igual síntoma |

### Prioridad: **MEDIA — antes de operar con AWS desde CLI recurrentemente**

---

## Riesgo 3 — Repositorio Git en directorio sincronizado por OneDrive ⚠️ BAJO

### Hallazgo
El repositorio Git vive en:
```
C:\Users\Rog\OneDrive\BCG Institute\Arquitectura Escalable\Proyecto_Final
```

OneDrive sincroniza la carpeta `.git/` con el resto. Esto puede producir:
- Conflictos cuando OneDrive sincroniza archivos `.git/index`, `.git/HEAD`, `.git/refs/` durante operaciones git activas
- Corrupción silenciosa de objetos del repo si OneDrive sube/baja archivos a medio escribir
- Performance degradado en repos grandes

### Mitigación recomendada

**Opción A — Mover el repositorio fuera de OneDrive:**

```powershell
# Detener cualquier proceso usando el repo (cerrar VS Code, terminales, etc.)
$src = "C:\Users\Rog\OneDrive\BCG Institute\Arquitectura Escalable\Proyecto_Final"
$dst = "C:\Users\Rog\dev\bsg-acmeco-rag"
New-Item -ItemType Directory -Path (Split-Path $dst) -Force
Move-Item $src $dst
```

**Opción B — Excluir `.git/` de OneDrive (configuración manual):**

OneDrive permite "excluir" carpetas específicas del sync vía configuración avanzada. Sin embargo, la implementación es frágil y cambia entre versiones de OneDrive.

### Estado actual
El autor eligió aceptar el riesgo en setup inicial. Si se observan errores tipo `git index corrupt` o `fatal: bad index file sha1 signature`, ejecutar Opción A inmediatamente.

### Prioridad: **BAJA — sólo si aparecen síntomas de corrupción**

---

## Checklist de hardening pre-producción

Antes de cualquier uso del pipeline en escenario más allá del académico (demos a Acme Co, deployment real con datos sensibles), confirmar:

- [ ] AWS root no se usa para operación — IAM user con MFA activo
- [ ] `AWS_CA_BUNDLE` configurado correctamente o IT publicó el bundle corporativo
- [ ] Repo movido fuera de OneDrive (o validado que no hay corrupciones)
- [ ] `terraform.tfstate` está en backend remoto (S3 + DynamoDB lock), nunca local
- [ ] `terraform.tfvars` está en `.gitignore` (verificado: sí)
- [ ] Aurora `enable_deletion_protection = true`
- [ ] CloudTrail activado para auditoría
- [ ] AWS Config activado para drift detection
- [ ] CloudWatch Cost Anomaly Detection con alarma a email
- [ ] Acceso a Bedrock revisado — sólo modelos necesarios habilitados
- [ ] KMS Customer Managed Keys en lugar de AWS Managed (si datos financieros lo requieren)
- [ ] Secrets Manager con rotación automática activada
- [ ] VPC Flow Logs activados (auditoría de red)

---

## Referencias

- [AWS IAM Best Practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
- [AWS CLI custom CA bundle](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-options.html#cli-configure-options-ca-bundle)
- [Why root is dangerous](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html#lock-away-credentials)
