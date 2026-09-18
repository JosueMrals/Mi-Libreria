# Firebase

## Stack inicial

- Firebase Authentication
- Firebase SQL Connect
- Firebase CLI
- Cloud SQL for PostgreSQL

## Preparación

La estructura base fue creada con la configuración oficial de Firebase SQL Connect.

## Recomendación de proyecto

Se debe asociar el directorio a un proyecto Firebase real cuando el propietario lo autorice.

## Reglas de seguridad

- No almacenar secretos reales dentro del repositorio.
- No incluir credenciales de Firebase Admin en las apps cliente.
- No crear `env` reales con claves sensibles.
- No desplegar producción sin aprobación explícita.
