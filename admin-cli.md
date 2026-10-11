# Moodle Admin CLI Commands Reference Guide

Moodle provides a powerful suite of Command Line Interface (CLI) scripts located in the `admin/cli/` directory. Running these commands directly bypasses web server timeouts and UI hangs, making them essential for troubleshooting, bulk operations, and general maintenance.

*Note: In an AWS Elastic Beanstalk environment, always execute these scripts using `sudo -u webapp php` to ensure the files are created and modified with the correct web server user permissions.*

## Part 1: Caching, Storage, and Cleanup

### 1. Purge All Caches

Wipes Moodle's UI, theme, and language caches, forcing the system to rebuild them from scratch. This is essential when updating theme logos, troubleshooting broken thumbnails, or after modifying the `$CFG->localcachedir`.

```bash
sudo -u webapp php /var/app/current/admin/cli/purge_caches.php

```

### 2. Force Moodle Cron

Executes the main Moodle cron process manually. This handles all standard background tasks like sending forum emails, calculating grades, and processing asynchronous queues.

```bash
sudo -u webapp php /var/app/current/admin/cli/cron.php

```

### 3. Execute a Specific Scheduled Task

Sometimes you cannot wait for the main cron cycle. This command allows you to force a specific background task to run immediately.

* **Example (File Trash Cleanup):** Forces Moodle to permanently delete orphaned files from the EFS drive's `trashdir` so you can upload a clean version.
```bash
sudo -u webapp php /var/app/current/admin/cli/scheduled_task.php --execute="\core\task\file_trash_cleanup_task"

```


* **Example (Course Module Deletion):** Flushes the queue for asynchronously deleting course modules if the web UI deletion process gets stuck.
```bash
sudo -u webapp php /var/app/current/admin/cli/scheduled_task.php --execute="\core_course\task\course_delete_modules"

```



### 4. Delete a Specific Course

Bypasses the web interface and background cron to forcefully delete a course and all of its associated enrollments, modules, and files synchronously.

```bash
sudo -u webapp php /var/app/current/admin/cli/delete_course.php --courseid=4

```

*(Replace `4` with the ID of the course you wish to delete).*

### 5. Nuke all Courses (WARNING: USE WITH CAUTION. IT WILL DELETE ALL COURSES)

This gets all course IDs (except the site front page, which is ID 1) and deletes them cleanly

```bash
for courseid in $(sudo -u webapp php /var/app/current/admin/cli/mysql_query.php "SELECT id FROM mdl_course WHERE id > 1"); do
    sudo -u webapp php /var/app/current/admin/cli/delete_course.php --courseid=$courseid
done
```

---

## Part 2: Common Moodle Maintenance Commands

Below are standard CLI tools highly recommended for managing a production Moodle environment.

### 5. Enable/Disable Maintenance Mode

Switches the site into maintenance mode, blocking all non-admin access while you perform server maintenance. This is much safer than using the web UI, as you cannot accidentally lock yourself out.

```bash
# Turn maintenance mode ON
sudo -u webapp php /var/app/current/admin/cli/maintenance.php --enable

# Turn maintenance mode OFF
sudo -u webapp php /var/app/current/admin/cli/maintenance.php --disable

```

### 6. Upgrade Moodle

Runs the Moodle database upgrade process. If you deploy a new version of Moodle via GitHub Actions, running this command applies the required database schema changes without needing to click through the web UI.

```bash
sudo -u webapp php /var/app/current/admin/cli/upgrade.php --non-interactive

```

### 7. Reset a User's Password

A lifesaver if an administrator gets locked out or if you need to manually intervene for a specific user. This securely salts and updates the password directly in the database.

```bash
sudo -u webapp php /var/app/current/admin/cli/reset_password.php --username=admin --password=NewStrongPassword123!

```

### 8. View or Update Configuration Values

Retrieves or changes values normally found in the `mdl_config` database table (Site administration settings).

```bash
# Check the maximum folder download size
sudo -u webapp php /var/app/current/admin/cli/cfg.php --name=maxsizetodownload --component=folder

# Disable the Language menu directly
sudo -u webapp php /var/app/current/admin/cli/cfg.php --name=langmenu --set=0

```

### 9. Identify and Uninstall Plugins

Allows you to list installed plugins, identify plugins whose files are missing from the disk, and forcefully uninstall them cleanly from the database.

```bash
# List all missing plugins
sudo -u webapp php /var/app/current/admin/cli/uninstall_plugins.php --show-missing

# Clean up the database for plugins that were deleted from the server
sudo -u webapp php /var/app/current/admin/cli/uninstall_plugins.php --purge-missing --run

```
