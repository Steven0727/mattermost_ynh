#!/bin/bash

#=================================================
# COMMON VARIABLES
#=================================================

# dependencies used by the app
pkg_dependencies="postgresql postgresql-contrib pgloader"

#=================================================
# PERSONAL HELPERS
#=================================================

mariadb-to-pg() {

		ynh_script_progression --message="Migrating to PostgreSQL database..." --weight=10

		mysqlpwd=$(ynh_app_setting_get --app=$app --key=mysqlpwd)
        
        # In old instance db_user is `mmuser`
        mysql_db_user="$db_user"
        if ynh_mysql_connect_as --user="mmuser" --password="$mysqlpwd" 2> /dev/null <<< ";"; then
            mysql_db_user="mmuser"
        fi

        # Initialize Postgresql db
		ynh_psql_test_if_first_run
		ynh_psql_setup_db --db_user=$db_user --db_name=$db_name --db_pwd=$mysqlpwd
		psqlpwd=$(ynh_app_setting_get --app=$app --key=psqlpwd)

        # Configure the new db and run mattermost in order to create tables
        ynh_write_var_in_file --file="$final_path/config/config.json" --key="DriverName" --value="postgres" --after="SqlSettings"
        ynh_write_var_in_file --file="$final_path/config/config.json" --key="DataSource" --value="postgres://$db_user:$psqlpwd@localhost:5432/$db_name?sslmode=disable&connect_timeout=10" --after="SqlSettings"
        cat "$final_path/config/config.json"
        pushd $final_path
        ynh_systemd_action --service_name="$app" --action="stop"
        set +e
		sudo -u mattermost timeout --preserve-status 30 "./bin/mattermost" 
        if [ "$?" != "0" ] && [ "$?" != "143" ] ; then
            ynh_die --message="Mattermost creation failed on mattermost running" --ret_code=1
        fi
        set -e
        popd

        # Some fixes to let the mariadb -> postgresql conversion working
        ynh_psql_execute_as_root --sql='DROP INDEX public.idx_fileinfo_content_txt;' --database=mattermost
        ynh_psql_execute_as_root --sql='DROP INDEX public.idx_posts_message_txt;' --database=mattermost
        ynh_mysql_execute_as_root --sql="ALTER TABLE mattermost.Users DROP COLUMN IF EXISTS acceptedtermsofserviceid;" --database=mattermost

        # Migrating from MySQL to PostgreSQL
        tmpdir="$(mktemp -d)"

        cat <<EOT > $tmpdir/commands.load
LOAD DATABASE
     FROM mysql://$mysql_db_user:$mysqlpwd@127.0.0.1:3306/$db_name
     INTO postgresql://$db_user:$psqlpwd@127.0.0.1:5432/$db_name

WITH include no drop, truncate, create no tables,
     create no indexes, preserve index names, no foreign keys,
     data only, workers = 16, concurrency = 1

SET MySQL PARAMETERS
net_read_timeout = '90',
net_write_timeout = '180'

ALTER SCHEMA '$db_name' RENAME TO 'public'

;
EOT
		pgloader $tmpdir/commands.load
        
        # Rebuild INDEX
        ynh_psql_execute_as_root --sql='CREATE INDEX idx_fileinfo_content_txt ON public.fileinfo USING gin (to_tsvector('\''english'\''::regconfig, content))' --database=mattermost
        ynh_psql_execute_as_root --sql='CREATE INDEX idx_posts_message_txt ON public.posts USING gin (to_tsvector('\''english'\''::regconfig, (message)::text));' --database=mattermost
		

		# Removinging MySQL database
		ynh_mysql_remove_db --db_user=$mysql_db_user --db_name=$db_name

}

#=================================================
# EXPERIMENTAL HELPERS
#=================================================

#=================================================
# FUTURE OFFICIAL HELPERS
#=================================================
