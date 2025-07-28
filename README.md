# Synology Photos Shared Folder Permissions - Reverse Engineering

## Background & Pain Point

Synology Photos manages user permissions using its own internal database, not the filesystem ACLs. This means:

- Users with read access to the `/photos` shared folder on the filesystem (e.g., via SMB/SAMBA) can see **all photos**, regardless of the restrictions set in Synology Photos.
- In Synology Photos, users only see the photos and folders they have been explicitly authorized to access, as defined in the Photos database.

**Pain Point:** There is a mismatch between what users can access via the filesystem and what they are allowed to see in Synology Photos. This can lead to privacy or security issues, as users may access files outside their intended scope if they use direct filesystem access.

**Goal:** The intention of this project is to find a way to align Synology Photos permissions (as managed in its database) with the actual filesystem ACLs/permissions, so that access is consistent whether users access photos via Synology Photos or directly through the filesystem.

## Reverse Engineering Setup: Extracting and Importing the Synology Photos Database

To analyze and reverse engineer Synology Photos permissions, the first step is to extract the database from your Synology NAS and import it into a local PostgreSQL instance for inspection.

### 1. Extract the Database from Synology NAS

Run the following commands on your Synology as root:

```sh
# as root
mkdir /volume1/pg_dump
chown postgres: /volume1/pg_dump
su - postgres
cd /volume1/pg_dump
pg_dump synofoto > synofoto.sql
```

This will create a SQL dump of the `synofoto` database.

### 2. Import into Local PostgreSQL (using Docker Compose)

Create a `docker-compose.yml` file with the following content:

```yaml
services:
  db:
    image: postgres:15
    container_name: synofoto-db
    restart: unless-stopped
    environment:
      POSTGRES_USER: syno
      POSTGRES_PASSWORD: synopass
      POSTGRES_DB: synofoto
    ports:
      - "5432:5432"
```

Start the database:

```sh
docker-compose up -d
```

Copy the SQL dump into the container:

```sh
docker cp ./synofoto.sql synofoto-db:/tmp/synofoto.sql
```

Prepare the import (create the required role):

```sh
docker exec -u postgres synofoto-db psql -d synofoto -c 'CREATE ROLE "SynologyPhotos";'
```

Import the database dump:

```sh
docker exec -it synofoto-db bash
psql -U syno -d synofoto -f /tmp/synofoto.sql
```

## Database Schema Overview

The main tables involved are:

- `folder`: Contains folder metadata. Shared folders have `id_user = 0`.
- `share_permission`: Stores permissions for users/groups on shared folders, linked via `passphrase_share`.
- `user_info`: Stores user information (id, uid, name).

## Permission Mapping

- Permissions are stored as bitmaps in the `permission` column (e.g., 3 for view, 7 for download, 15 upload, 31 for manage)
- Each row in `share_permission` links a user/group (`target_id`) to a shared folder via `passphrase_share`.

## How to Extract User Permissions for a Shared Folder

To list all users with permissions on a shared folder of id = 92 (excluding system user 0):

```sql
SELECT sp.target_id AS user_id, ui.uid AS username, ui.name AS user_fullname, sp.permission
FROM share_permission sp
JOIN user_info ui ON sp.target_id = ui.id
JOIN folder f ON f.passphrase_share = sp.passphrase_share
WHERE f.id = 92 AND sp.target_id != 0 AND sp.permission > 0;
```

For folder id = 92, the query returns:

| user_id | username | user_fullname | permission |
|---------|----------|---------------|------------|
| 3       | 1026     | valentin      | 15         |
| 10      | 1033     | bonzac        | 3          |
| 5       | 1028     | mathilde      | 3          |
| 11      | 1029     | famille       | 3          |

And here was the source:
![Reverse Engineer overview](synofoto.drawio.png)

## How to apply those permissions to Filesytem (used for SAMBA/SMB etc.)
[In progress]

## Conclusion

This approach allows you to enumerate all users with access to a shared folder in Synology Photos, along with their permission levels, by querying the underlying database.