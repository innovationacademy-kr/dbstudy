# disk_add_volume

- **B.  볼륨  추가  [disk_add_volume()]**
    - 순서
        1. extend_info, boot_Db_param의 정보를 바탕으로 DBDEF_VOL_EXT_INFO 구조체를 할당, 초기화한다.
        2. 새로운 볼륨을 위한 충분한 공간이 있는지 확인한다.
        3. disk_format()을 통해 새로운 OS 파일을 만들고 볼륨헤더의 정보들과 섹터테이블등 볼륨정보를 초기화시킨다.
        4. 영구타입볼륨이라면 볼륨 인포 파일(_vinf) 업데이트
        5. 새로운 볼륨정보를 boot_Db_param에 업데이트한다.
        6. 디스크 캐시를 업데이트한다
    - **함수원형**
        
        ```c
        static int disk_add_volume (THREAD_ENTRY * thread_p, DBDEF_VOL_EXT_INFO * extinfo, VOLID * volid_out, DKNSECTS * nsects_free_out)
        ```
        
    - **매개변수**
        
        ```c
        THREAD_ENTRY * thread_p; //쓰레드
        DBDEF_VOL_EXT_INFO * extinfo; //볼륨확장 정보 구조체
        VOLID * volid_out; //새로 생성한 볼륨의 id
        DKNSECTS * nsects_free_out; //output the number of free sectors in new volume
        ```
        
    - **사용변수(데이터)**
        
        ```c
        char fullname[PATH_MAX]; //파일이름
        VOLID volid; // //새로 생성한 볼륨의 id 
        DKNSECTS nsect_part_max; // 시스템별 허용가능한 nsect 최대길이?
        int error_code = NO_ERROR;
        bool can_overwrite;
        ```
        
    - **주요 구조체**
    
		```c
		typedef struct dbdef_vol_ext_info DBDEF_VOL_EXT_INFO;
		struct dbdef_vol_ext_info
		{
			const char *path; /*볼륨이 생성될 경로, NULL이면 시스템 파라미터 값 */
			const char *name;	/* 볼륨 명, NULL이면 [db_name].ext[volid] 형식으로 생성 */
			const char *comments;	/* Comments which are included in the volume extension header. */
			int max_npages; /* 생성하는 볼륨의 최대 페이지 */
			int extend_npages; /* Number of pages to extend - used for generic volume only */
			INT32 nsect_total; /* 생성 볼륨의 현재 섹터 수 */
			INT32 nsect_max; /* 볼륨이 확장할 때 가질 수 있는 최대 섹터 수 */
			int max_writesize_in_sec;	/* the amount of volume written per second */
			DB_VOLPURPOSE purpose;	/* The purpose of the volume extension. One of the following: -
							* DB_PERMANENT_DATA_PURPOSE, DB_TEMPORARY_DATA_PURPOSE */
			DB_VOLTYPE voltype;		/* Permanent of temporary volume type */
			bool overwrite;
		};
		
		/*boot_Db_param은 볼륨마다 있는 시스템 힙 파일에 저장된 볼륨에 대한 파라미터들을 지니고 
		있는 전역변수이다.*/
		typedef struct boot_dbparm BOOT_DB_PARM;
		struct boot_dbparm
		{
		VFID trk_vfid;		/* Tracker of files */
		HFID hfid;			/* Heap file where this information is stored. It is only used for validation purposes */
		HFID rootclass_hfid;		/* Heap file where classes are stored */
		#if 1				/* TODO - not used */
		EHID classname_table;		/* The hash file of class names */
		#endif
		CTID ctid;			/* The catalog file */
		/* TODO: Remove me */
		VFID query_vfid;		/* Query file */
		char rootclass_name[10];	/* Name of the root class */
		OID rootclass_oid;		/* OID of the root class */
		VOLID nvols;			/*  생성된 볼륨 수 */
		VOLID temp_nvols;		/* 사용생성된 임시 볼륨의 수 */
		VOLID last_volid;		/* 사용 마지막 볼륨 식별자 */
		VOLID temp_last_volid;	/* 사용 다음 임시 볼륨 식별자입니다. 이것은 더 높은 숫자에서 더 낮은 숫자로 이동합니다 */
		int vacuum_log_block_npages;	/* Number of pages for vacuum data file */
		VFID vacuum_data_vfid;	/* Vacuum data file identifier */
		VFID dropped_files_vfid;	/* Vacuum dropped files file identifier */
		HFID tde_keyinfo_hfid;	/* Heap file where tde key info (TDE_KEYINFO) is stored */
		};
		
		```
    
    - 주요함수
        
        ```cpp
        static int disk_add_volume(THREAD_ENTRY *thread_p, DBDEF_VOL_EXT_INFO *extinfo, VOLID *volid_out, DKNSECTS *nsects_free_out);
        
        /*boot_Db_parm 을 활용하여 새로 생성한 vol 의 fullname, volid 만들기  */
        int boot_get_new_volume_name_and_id (THREAD_ENTRY * thread_p, DB_VOLTYPE voltype, const char *given_path, const char *given_name, char *fullname_newvol_out, VOLID * volid_newvol_out);
        
        /*전체 이름 통해서 경로를 알아낸다*/
        char * fileio_get_directory_path (char *path_p, const char *full_name_p);
        
        /*fullname을 통해 파일 이름 알아낸다  '/' 폴더구분문자 로 경로를 알수있다. */
        const char * fileio_get_base_file_name (const char *full_name_p)
        
        /*path/name형태의 fullname을 생성*/
        void fileio_make_volume_ext_given_name (char *vol_ext_full_name_p, const char *ext_path_p, const char *ext_name_p);
        
        /*path/name + volid 형태의 fullname을 생성*/
        void fileio_make_volume_ext_name (char *vol_ext_full_name_p, const char *ext_path_p, const char *ext_name_p, VOLID vol_id)
        
        /*path / name _t volid 형태의 fullname을 생성*/
        void fileio_make_volume_temp_name (char *vol_tmp_full_name_p, const char *tmp_path_p, const char *tmp_name_p, VOLID vol_id);
        
        /*윈도우는 폴더구분자가 달라 \로 표시된다. 이를 수정하여 실제 경로가 존재하는지 검사*/
        char * realpath (const char *path, char *resolved_path);
        
        /*파일의 정보를 바탕으로 섹터 최대 크기 설정*/
        DKNSECTS fileio_get_number_of_partition_free_sectors (const char *path_p)
        
        /*boot_Db_parm 값을 최신화 시켜준다
        	볼륨 전체개수, 마지막 길이
        	heap_flush
        	볼륨과 실제디스크 상태 동기화
        */
        int boot_dbparm_save_volume(THREAD_ENTRY *thread_p, DB_VOLTYPE voltype, VOLID volid);
        ```
        
        - disk_add_volume
            
            ```c
            static int
            disk_add_volume(THREAD_ENTRY *thread_p, DBDEF_VOL_EXT_INFO *extinfo, VOLID *volid_out, DKNSECTS *nsects_free_out)
            {
            	char fullname[PATH_MAX]; // 볼륨 파일 이름 path + file_name
            	VOLID volid;			 //볼륨 id
            	DKNSECTS nsect_part_max; // 시스템별 허용가능한 nsect 최대길이?
            	int error_code = NO_ERROR;
            	bool can_overwrite;
            
            	/* how it works:
            	 *
            	 * we need to do several steps to add a new volume:
            	 * 1. get from boot the full name (path + file name) and volume id.
            	 * 2. make sure there is enough space on disk to handle a new volume.
            	 * 3. notify page buffer (it needs to track permanent/temporary volumes).
            	 * 4. format new volume.
            	 * 5. update volume info file (if permanent volume).
            	 * 6. update boot_Db_parm.
            	 */
            
            	/* disk_Cache 의 볼륨이 가득찼는지 검사 */
            	if (disk_Cache->nvols_perm + disk_Cache->nvols_temp >= LOG_MAX_DBVOLID) // LOG_MAX_DBVOLID = VOLID_MAX - 1;
            	{
            		/* oops, too many volumes */
            		er_set(ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_BO_MAXNUM_VOLS_HAS_BEEN_EXCEEDED, 1, LOG_MAX_DBVOLID);
            		return ER_BO_MAXNUM_VOLS_HAS_BEEN_EXCEEDED;
            	}
            
            	/* 
            		get from boot the volume name and identifier
            		boot_Db_parm 을 활용하여 새로 생성한 vol 의 fullname, volid 만들기
            		boot_Db_param은 볼륨마다 있는 시스템 힙 파일에 저장된 볼륨에 대한 파라미터들을 지니고 있는 전역변수이다.
            	*/
            	error_code =
            		boot_get_new_volume_name_and_id(thread_p, extinfo->voltype, extinfo->path, extinfo->name, fullname, &volid);
            	if (error_code != NO_ERROR)
            	{
            		ASSERT_ERROR();
            		return error_code;
            	}
            
            	/* 
            		make sure the total and max size are rounded
            		nsect_max, nsect_total 반올림 왜 해주는지?
            		발표시 여쭈어볼것.
            	*/
            	extinfo->nsect_max = DISK_SECTS_ROUND_UP(extinfo->nsect_max);	  //볼륨들의 합산 최대 섹터 수
            	extinfo->nsect_total = DISK_SECTS_ROUND_UP(extinfo->nsect_total); //예약 요청된 섹터수
            
            	disk_log("disk_add_volume", "add new %s volume with purpose %s:\n"
            								"\tname=%s\n"
            								"\tcomments=%s\n"
            								"\tpath=%s\n"
            								"\tfullname = %s\n"
            								"\ttotal sectors = %d\n"
            								"\tmax sectors = %d",
            			 disk_type_to_string(extinfo->voltype),
            			 disk_purpose_to_string(extinfo->purpose), extinfo->name ? extinfo->name : "(UNKNOWN)",
            			 extinfo->comments ? extinfo->comments : "(UNKNOWN)", extinfo->path ? extinfo->path : "(UNKNOWN)",
            			 fullname, extinfo->nsect_total, extinfo->nsect_max);
            
            /* fullname 구하기 */
            #if !defined(WINDOWS)
            	{
            		 /*링크를 해주는 하는 이유는..?*/
            		DBDEF_VOL_EXT_INFO temp_extinfo = *extinfo;
            		char vol_realpath[PATH_MAX];
            		char link_path[PATH_MAX];
            		char link_fullname[PATH_MAX];
            		struct stat stat_buf;
            
            		if (stat(fullname, &stat_buf) == 0 /* file exists */
            			&& S_ISCHR(stat_buf.st_mode))  /* is the raw device? tat_buf.st_mode 의 값이S_IFCHR 인지 확인*/
            		{
            			temp_extinfo.path = fileio_get_directory_path (link_path, boot_db_full_name()); //경로 받아옴
            			if (temp_extinfo.path == NULL)
            			{
            				link_path[0] = '\0';
            				temp_extinfo.path = link_path;
            			}
            			/*fullname을 통해 파일 이름 알아낸다  '/' 폴더구분문자 로 경로를 알수있다. */
            			temp_extinfo.name = fileio_get_base_file_name(boot_db_full_name());
            			/*path/name + volid 형태의 fullname을 생성*/
            			fileio_make_volume_ext_name(link_fullname, temp_extinfo.path, temp_extinfo.name, volid);
            
            			/*윈도우는 폴더구분자가 달라 \로 표시된다. 이를 수정하여 실제 경로가 존재하는지 검사*/
            			if (realpath(fullname, vol_realpath) != NULL) // WINDOWS 가 정의 되있지 않은데...실행이 되는지? 찾
            			{
            				strcpy(fullname, vol_realpath);
            			}
            			/* 링크 파일 삭제 */
            			(void)unlink(link_fullname); 
            			/*링크 연결 해주기*/
            			if (symlink(fullname, link_fullname) != 0)
            			{
            				er_set(ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_BO_CANNOT_CREATE_LINK, 2, fullname, link_fullname);
            				return ER_BO_CANNOT_CREATE_LINK;
            			}
            			 /*link_fullname 와 fullname이 같아 보이는데 복사하는 이유는?*/
            			strcpy(fullname, link_fullname);
            
            			/* we don't know character special files size 
            				섹터 하나의 최대크기 구하는것 같다..
            				
            				파일의 크기를 모르기때문에 가장
            				off_t == long long      
            				34비트와 64비트 컴퓨터의 크기가 다르다.   
            				32bit == 4byte
            				64bit == 8 byte
            				INT_MAX == 2147483647
            
            				((sizeof(off_t) == 4) ? (INT_MAX / (page_size)) : INT_MAX)  /  64(DISK_SECTOR_NPAGES)
            
            				32bit
            				(INT_MAX / (page_size))  / DISK_SECTOR_NPAGES
            
            				64bit
            				INT_MAX / DISK_SECTOR_NPAGES
            				
            				왜 32bit 에서는 IO_PAGESIZE 로 나누어 주는지..
            				64 bit 에서는 페이지 크기가  INT_MAX / 64와 동일..
            				섹터 하나의 최대값?!
            			*/
            			nsect_part_max = VOL_MAX_NSECTS(IO_PAGESIZE);  // IO_PAGESIZE == 16K (16 * 1024)
            		}
            		else
            		{
            			nsect_part_max = fileio_get_number_of_partition_free_sectors(fullname); // long long  
            		}
            	}
            #else  /* WINDOWS */
            	nsect_part_max = fileio_get_number_of_partition_free_sectors(fullname);
            #endif /* WINDOWS */
            
            	if (nsect_part_max >= 0 && nsect_part_max < extinfo->nsect_max)
            	{
            		/* not enough space on disk */
            		er_set(ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_IO_FORMAT_OUT_OF_SPACE, 5, fullname,
            			   DISK_SECTS_NPAGES(extinfo->nsect_max), DISK_SECTS_SIZE(extinfo->nsect_max) / 1204 /* KB */,
            			   DISK_SECTS_NPAGES(nsect_part_max), DISK_SECTS_SIZE(nsect_part_max) / 1204 /* KB */);
            		return ER_IO_FORMAT_OUT_OF_SPACE;
            	}
            
            	if (extinfo->comments == NULL)
            	{
            		extinfo->comments = "Volume Extension";
            	}
            	extinfo->name = fullname; //확장정보에 파일이름 대입
            
            	if (!extinfo->overwrite && fileio_is_volume_exist(extinfo->name))
            	{
            		if (disk_can_overwrite_data_volume(thread_p, extinfo->name, &can_overwrite) != NO_ERROR || can_overwrite == false)
            		{
            			er_set(ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_BO_VOLUME_EXISTS, 1, extinfo->name);
            			return ER_BO_VOLUME_EXISTS;
            		}
            	}
            
            	log_sysop_start(thread_p);
            
            	/* with disk_format, we start fixing pages. page fixing may depend on */
            	/* 타입에 따라 볼륨 크기 증가 */
            	if (extinfo->voltype == DB_PERMANENT_VOLTYPE)
            	{
            		disk_Cache->nvols_perm++;
            	}
            	else
            	{
            		disk_Cache->nvols_temp++;
            	}
            	/*	캐시에 볼륨 목적 대입 */
            	disk_Cache->vols[volid].purpose = extinfo->purpose;
            
            	/* 볼륨 확장 */
            	error_code = disk_format(thread_p, boot_db_full_name(), volid, extinfo, nsects_free_out);
            	if (error_code != NO_ERROR)
            	{
            		ASSERT_ERROR();
            		goto exit;
            	}
            
            	if (extinfo->voltype == DB_PERMANENT_VOLTYPE)
            	{
            		if (logpb_add_volume(NULL, volid, extinfo->name, DB_PERMANENT_DATA_PURPOSE) == NULL_VOLID)
            		{
            			ASSERT_ERROR_AND_SET(error_code);
            			goto exit;
            		}
            	}
            
            	/* this must be last step */
            	error_code = boot_dbparm_save_volume(thread_p, extinfo->voltype, volid);
            	if (error_code != NO_ERROR)
            	{
            		ASSERT_ERROR();
            		if (extinfo->voltype == DB_TEMPORARY_VOLTYPE)
            		{
            			/* rollback will not remove volume, we have to do it manually */
            			if (disk_unformat(thread_p, extinfo->name) != NO_ERROR)
            			{
            				assert(false);
            			}
            		}
            		goto exit;
            	}
            
            	assert(error_code == NO_ERROR);
            	*volid_out = volid;
            
            exit:
            	if (error_code == NO_ERROR)
            	{
            		log_sysop_commit(thread_p);
            	}
            	else
            	{
            		log_sysop_abort(thread_p);
            
            		/* undo incrementing volume count. rollback won't do it. */
            		if (extinfo->voltype == DB_TEMPORARY_VOLTYPE)
            		{
            			disk_Cache->nvols_temp--;
            		}
            		else
            		{
            			disk_Cache->nvols_perm--;
            		}
            	}
            
            	return error_code;
            }
            ```
            
        - boot_get_new_volume_name_and_id
            
            ```c
            int boot_get_new_volume_name_and_id(THREAD_ENTRY *thread_p, DB_VOLTYPE voltype, const char *given_path, const char *given_name, char *fullname_newvol_out, VOLID *volid_newvol_out)
            {
            	char buf_temp_path[PATH_MAX];
            	const char *temp_path = NULL;
            	const char *temp_name = NULL;
            
            	if (voltype == DB_PERMANENT_VOLTYPE) /*영구볼륨 타이인 경우*/
            	{
            		*volid_newvol_out = boot_Db_parm->last_volid + 1; //마지막 volid + 1 
            		/*VOLID 최대값을 초과하거나 임시 볼륨 id가 0보다 크고  임시볼륨id의 값봐 큰경우 -- 임시볼륨은 역순으로 저장되기떄문! */
            		if (*volid_newvol_out > LOG_MAX_DBVOLID || (boot_Db_parm->temp_nvols > 0 && *volid_newvol_out >= boot_Db_parm->temp_last_volid))
            		{
            			/* should be caught early */
            			assert(false);
            			er_set(ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_BO_MAXNUM_VOLS_HAS_BEEN_EXCEEDED, 1, LOG_MAX_DBVOLID);
            			return ER_BO_MAXNUM_VOLS_HAS_BEEN_EXCEEDED;
            		}
            
            		/*temp_path 구하기 */
            		if (given_path != NULL)
            		{
            			temp_path = given_path;
            		}
            		else //?언제 기본경로를 사용하는지?  예상은 게스트모드?
            		{
            			temp_path = prm_get_string_value(PRM_ID_IO_VOLUME_EXT_PATH); // prm_Def[181].value
            			if (temp_path == NULL)
            			{
            				/*?? boot_Db_full_name에는 어떤값이 있는지?*/
            				temp_path = fileio_get_directory_path(buf_temp_path, boot_Db_full_name); 
            				if (temp_path == NULL)
            				{
            					buf_temp_path[0] = '\0';
            					temp_path = buf_temp_path;
            				}
            			}
            		}
            		if (given_name != NULL) //temp_name 구하기
            		{
            			temp_name = given_name;
            			/*path/name 으로 fullname 만들어준다*/
            			fileio_make_volume_ext_given_name(fullname_newvol_out, temp_path, given_name); 
            		}
            		else
            		{
            			temp_name = fileio_get_base_file_name(boot_Db_full_name);
            			/*path/name + volid 형태의 fullname을 생성*/
            			fileio_make_volume_ext_name(fullname_newvol_out, temp_path, temp_name, *volid_newvol_out);
            		}
            	}
            	else /*임시 볼륨 타입인 경우*/
            	{
            		/*임시 볼륨의 위치 지정, 0보다 큰경우 이미 갓이 있기떄문에 마지막 위치 - 1을 해주고  0이인경우 volid최대값을 지정해준다*/
            		*volid_newvol_out = boot_Db_parm->temp_nvols > 0 ? boot_Db_parm->temp_last_volid - 1 : LOG_MAX_DBVOLID;
            		/*영구볼륨의 영역을 침범하게 되면*/
            		if (*volid_newvol_out <= boot_Db_parm->last_volid)
            		{
            			/* should be caught early */
            			assert(false);
            			er_set(ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_BO_MAXNUM_VOLS_HAS_BEEN_EXCEEDED, 1, LOG_MAX_DBVOLID);
            			return ER_BO_MAXNUM_VOLS_HAS_BEEN_EXCEEDED;
            		}
            		/*임시 볼륨은 경로와 이름이 주어져야한다.*/
            		assert(given_path == NULL && given_name == NULL);
            
            		temp_path = (char *)prm_get_string_value(PRM_ID_IO_TEMP_VOLUME_PATH); // prm_Def[180].value
            		if (temp_path == NULL || temp_path[0] == '\0')
            		{
            			temp_path = fileio_get_directory_path(buf_temp_path, boot_Db_full_name);
            		}
            		temp_name = fileio_get_base_file_name(boot_Db_full_name);
            		/*path / name _t volid 형태의 fullname을 생성*/
            		fileio_make_volume_temp_name(fullname_newvol_out, temp_path, temp_name, *volid_newvol_out);
            	}
            
            	return NO_ERROR;
            }
            ```
            
        - fileio_get_directory_path
            
            ```c
            char * fileio_get_directory_path (char *path_p, const char *full_name_p)
            {
              const char *base_p;
              size_t path_size;
              
              /*fullname 을 활용하여 경로 알아내기*/
              base_p = fileio_get_base_file_name (full_name_p);
            
              assert (base_p >= full_name_p);
            
              if (base_p == full_name_p) //? 언제 이런경우가 생기는지... 둘다 NULL인경우?
                {
                  /* Same pointer, the file does not contain a path/directory portion. Use the current directory */
                  if (getcwd (path_p, PATH_MAX) == NULL) // 현재경로를 얻어오는데, NNULL이라면
            	{
            	  er_set_with_oserror (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_BO_CWD_FAIL, 0);
            	  *path_p = '\0';
            	}
                }
              else
                {
            	// full_name(path + name) 에서 - name의 주소를 빼면 patj 의  길이가나옴.
                  path_size = (size_t) (base_p - full_name_p - 1); 
                  if (path_size > PATH_MAX)
            	{
            	  path_size = PATH_MAX;
            	}
            	/*복사*/
                  memcpy (path_p, full_name_p, path_size);
                  path_p[path_size] = '\0';
                }
            
              return path_p;
            }
            ```
            
        - fileio_get_base_file_name
            
            ```c
            const char * 
            fileio_get_base_file_name (const char *full_name_p)
            {
              const char *no_path_name_p;
            
              no_path_name_p = strrchr (full_name_p, PATH_SEPARATOR); //  '/' 가 마지막으로 나오는 주소 탐색
            #if defined(WINDOWS)
              {
                const char *nn_tmp = strrchr (full_name_p, '/');
                if (no_path_name_p < nn_tmp)
                  {
            	no_path_name_p = nn_tmp;
                  }
              }
            #endif /* WINDOWS */
              if (no_path_name_p == NULL)
                {
                  no_path_name_p = full_name_p;
                }
              else
                {
                  no_path_name_p++;		/* Skip to the name */
                }
            
              return no_path_name_p;
            }
            ```
            
        - fileio_make_volume_ext_given_name
            
            ```c
            void fileio_make_volume_ext_given_name (char *vol_ext_full_name_p, const char *ext_path_p, const char *ext_name_p)
            {
              sprintf (vol_ext_full_name_p, "%s%s%s", ext_path_p, FILEIO_PATH_SEPARATOR (ext_path_p), ext_name_p);
            }
            ```
            
        - fileio_make_volume_ext_name
            
            ```c
            void fileio_make_volume_ext_name (char *vol_ext_full_name_p, const char *ext_path_p, const char *ext_name_p, VOLID vol_id)
            {
              sprintf (vol_ext_full_name_p, "%s%s%s%s%03d", ext_path_p, FILEIO_PATH_SEPARATOR (ext_path_p), ext_name_p,
            	   FILEIO_VOLEXT_PREFIX, vol_id);
            }
            ```
            
        - fileio_make_volume_temp_name
            
            ```c
            void fileio_make_volume_temp_name (char *vol_tmp_full_name_p, const char *tmp_path_p, const char *tmp_name_p, VOLID vol_id)
            {
              sprintf (vol_tmp_full_name_p, "%s%c%s%s%03d", tmp_path_p, PATH_SEPARATOR, tmp_name_p, FILEIO_VOLTMP_PREFIX, vol_id);
            }
            ```
            
        - fileio_get_number_of_partition_free_sectors
            
            ```c
            DKNSECTS fileio_get_number_of_partition_free_sectors (const char *path_p)
            {
            #if defined(WINDOWS)
              return (DKNSECTS) free_space (path_p, IO_SECTORSIZE);
            #else /* WINDOWS */
              int vol_fd;
              INT64 nsectors_of_partition = -1;
            #if defined(SOLARIS)
              struct statvfs buf;
            #else /* SOLARIS */
              struct statfs buf; /*파일 시스템의 정보*/
            #endif /* SOLARIS */
            
            #if defined(SOLARIS)
              if (statvfs (path_p, &buf) == -1)
            #elif defined(AIX)
              if (statfs ((char *) path_p, &buf) == -1)
            #else /* AIX */
              if (statfs (path_p, &buf) == -1) /*파일시스템 정보 가져오기*/
            #endif /* AIX */
                {
            		/*파일 존재하지 않을시 파일생성*/
                  if (errno == ENOENT
            	  && ((vol_fd = fileio_open (path_p, FILEIO_DISK_FORMAT_MODE, FILEIO_DISK_PROTECTION_MODE)) != NULL_VOLDES))
            	{
            	  /* The given file did not exist. We create it for temporary consumption then it is removed */
            	  nsectors_of_partition = fileio_get_number_of_partition_free_sectors (path_p);  //생성한 파일 경로로 다시 호출
            
            	  /* Close the file and remove it */
            	  fileio_close (vol_fd);
            	  (void) remove (path_p);
            	}
                  else
            	{
            	  er_set_with_oserror (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_IO_MOUNT_FAIL, 1, path_p);
            	}
                }
              else
                {
                  const size_t f_avail_size = buf.f_bsize * buf.f_bavail; // 최적화된 전송 블럭 크기 * 비-슈퍼 유저를 위한 여유 블럭들
                  nsectors_of_partition = f_avail_size / IO_SECTORSIZE; //블럭을 섹터크리로 나누어준다
                  if (nsectors_of_partition < 0 || nsectors_of_partition > INT_MAX)
            	{
            	  nsectors_of_partition = INT_MAX;
            	}
                }
            
              if (nsectors_of_partition < 0)
                {
                  return -1;
                }
              else
                {
                  assert (nsectors_of_partition <= INT_MAX);
            
                  return (DKNSECTS) nsectors_of_partition;
                }
            #endif /* WINDOWS */
            }
            ```
            
        - boot_dbparm_save_volume
            
            ```c
            int boot_dbparm_save_volume(THREAD_ENTRY *thread_p, DB_VOLTYPE voltype, VOLID volid)
            {
            	VPID vpid_boot_bp_parm;
            	BOOT_DB_PARM save_boot_db_parm = *boot_Db_parm;
            
            	int error_code = NO_ERROR;
            
            	assert(log_check_system_op_is_started(thread_p));
            	/*타입에따라 볼륨개수와 마지막 주소 최신화*/
            	if (voltype == DB_PERMANENT_VOLTYPE)
            	{
            		assert(boot_Db_parm->nvols >= 0);
            		if (volid != boot_Db_parm->last_volid + 1)
            		{
            			assert_release(false);
            			error_code = ER_FAILED;
            			goto exit;
            		}
            		boot_Db_parm->last_volid = volid;
            		boot_Db_parm->nvols++;
            	}
            	else
            	{
            		if (boot_Db_parm->temp_nvols < 0 || (boot_Db_parm->temp_nvols == 0 && volid != LOG_MAX_DBVOLID) || (boot_Db_parm->temp_nvols > 0 && boot_Db_parm->temp_last_volid - 1 != volid))
            		{
            			/* invalid volid */
            			assert_release(false);
            			error_code = ER_FAILED;
            			goto exit;
            		}
            		boot_Db_parm->temp_nvols++;
            		boot_Db_parm->temp_last_volid = volid;
            	}
            
            	/* todo: is flush needed? */
            	VPID_GET_FROM_OID(&vpid_boot_bp_parm, boot_Db_parm_oid);
            	log_append_undo_data2(thread_p, RVPGBUF_FLUSH_PAGE, NULL, NULL, 0, sizeof(vpid_boot_bp_parm), &vpid_boot_bp_parm);
            
            	error_code = boot_db_parm_update_heap(thread_p);
            	if (error_code != NO_ERROR)
            	{
            		ASSERT_ERROR();
            		*boot_Db_parm = save_boot_db_parm;
            		goto exit;
            	}
            
            	/* flush the boot_Db_parm object. this is not necessary but it is recommended in order to mount every known volume
            	 * during restart. that may not be possible during media crash though. */
            	heap_flush(thread_p, boot_Db_parm_oid);
            	/*볼륨과 실제디스크 상태 동기화*/
            	fileio_synchronize(thread_p, fileio_get_volume_descriptor(boot_Db_parm_oid->volid), NULL, FILEIO_SYNC_ALSO_FLUSH_DWB); /* label? */
            
            exit:
            	return error_code;
            }
            ```