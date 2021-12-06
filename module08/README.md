``` C
/* The double write buffer structure. */
typedef struct double_write_buffer DOUBLE_WRITE_BUFFER;
struct double_write_buffer
{
  bool logging_enabled; /* logging_enabled 를 false 로 설정 */
  DWB_BLOCK *blocks;		/* The blocks in DWB. */
  unsigned int num_blocks;	/* The total number of blocks in DWB - power of 2. */
  unsigned int num_pages;	/* The total number of pages in DWB - power of 2. */
  unsigned int num_block_pages;	/* The number of pages in a block - power of 2. */
  unsigned int log2_num_block_pages;	/* 로그 from block number of pages. */
  volatile unsigned int blocks_flush_counter;	/* The blocks flush counter. */
  volatile unsigned int next_block_to_flush;	/* Next block to flush */

  pthread_mutex_t mutex;	/* The mutex to protect the wait queue. */
  DWB_WAIT_QUEUE wait_queue;	/* The wait queue, used when the DWB structure changed. */

  UINT64 volatile position_with_flags;
  /* The current position in double write buffer and flags. Flags keep the
	* state of each block (started, ended), create DWB status, modify DWB status.
	*/
  dwb_hashmap_type slots_hashmap;	/* The slots hash. */
  int vdes;			/* The volume file descriptor. */

  DWB_BLOCK *volatile file_sync_helper_block;	/* The block that will be sync by helper thread. */

  // *INDENT-OFF*
  double_write_buffer ()
    : logging_enabled (false)
    , blocks (NULL)
    , num_blocks (0)
    , num_pages (0)
    , num_block_pages (0)
    , log2_num_block_pages (0)
    , blocks_flush_counter (0)
    , next_block_to_flush (0)
    , mutex PTHREAD_MUTEX_INITIALIZER
    , wait_queue DWB_WAIT_QUEUE_INITIALIZER
    , position_with_flags (0)
    , slots_hashmap {}
    , vdes (NULL_VOLDES)
    , file_sync_helper_block (NULL)
  {
  }
  // *INDENT-ON*
};

static DOUBLE_WRITE_BUFFER dwb_Global;
```

### Wait Queue
```C
/* DWB queue.  */
typedef struct double_write_wait_queue DWB_WAIT_QUEUE;

struct double_write_wait_queue
{
  DWB_WAIT_QUEUE_ENTRY *head;	/* Queue head. */
  DWB_WAIT_QUEUE_ENTRY *tail;	/* Queue tail. */
  DWB_WAIT_QUEUE_ENTRY *free_list;	/* Queue free list */

  int count;			/* Count queue elements. */
  int free_count;		/* Count free list elements. */
};
```

### DWB_WAIT_QUEUE_ENTRY
``` C
/* Queue entry. */
typedef struct double_write_wait_queue_entry DWB_WAIT_QUEUE_ENTRY;

struct double_write_wait_queue_entry
{
  void *data;			/* The data field. */
  DWB_WAIT_QUEUE_ENTRY *next;	/* The next queue entry field. */
};
```

### dwb_hashmap_type
``` C
using dwb_hashmap_type = cubthread::lockfree_hashmap<VPID, dwb_slots_hash_entry>;
```
Hash Map : Key, value 값으로 데이터가 저장된다.   
해싱(Hashing)검색을 사용하기 때문에 대용량 데이터 관리에 좋은 성능을 보인다.   
key : 중복을 허용하지 않음   
value : 중복 허용   

#### Hash
- 키(Key)값을 해쉬 함수(Hash Function)라는 수식에 대입하여 계산된 결과를 주소로 사용하여 바로 값(Value)에 접근하게 할 수 있는 방법

#### vdes
- fileio_format() 함수에서 npaes 의 Volume을 초기화하고 마운트 하여 반환하는 값
- Error 상황일때 NULL_VOLDES 값 저장

### file_sync_helper_block
- sync helper daemon 이 주기적으로 file_sync_helper()를 호출해서 DB로 Page를 flush.
- file_sync_helper_block 이 참조한 Block을 fsync 한 뒤, NULL로 초기화

### Volatile 변수
- 최적화 등 컴파일러의 역할을 제한하는 역할.
- 주로 최적화와 관련하여 volatile가 선언된 변수는 최적화에서 제외된다.
- OS와 연관되어 장치제어를 위한 주소체계에서 지정한 주소를 직접 액세스하는 방식을 지정할 수도 있다.
- 리눅스 커널 등의 OS에서 메모리 주소는 MMU와 연관 된 주소체계로 논리주소와 물리주소 간의 변환이 이루어진다. 경우에 따라 이런 변환을 제거하는 역할을 한다. 또한 원거리 메모리 점프 기계어 코드 등의 제한을 푼다.

### **dwb_create_internal**

```cpp
/*
 * dwb_create_internal () - Create double write buffer.
 *
 * return   : Error code.
 * thread_p (in): The thread entry.
 * dwb_volume_name (in) : The double write buffer volume name.
 * current_position_with_flags (in/out): Current position with flags.
 *
 *  Note: Is user responsibility to ensure that no other transaction can access DWB structure, during creation.
 */
STATIC_INLINE int
dwb_create_internal (THREAD_ENTRY * thread_p, const char *dwb_volume_name, UINT64 * current_position_with_flags)
{
  int error_code = NO_ERROR;
  unsigned int double_write_buffer_size, num_blocks = 0;
  unsigned int i, num_pages, num_block_pages;
  int vdes = NULL_VOLDES;
  DWB_BLOCK *blocks = NULL;
  UINT64 new_position_with_flags;

  const int freelist_block_count = 2;
  const int freelist_block_size = DWB_SLOTS_FREE_LIST_SIZE;

  assert (dwb_volume_name != NULL && current_position_with_flags != NULL);

  double_write_buffer_size = prm_get_integer_value (PRM_ID_DWB_SIZE);
  num_blocks = prm_get_integer_value (PRM_ID_DWB_BLOCKS);
// PRM_ID_DWB_SIZE : defualt 2M
// PRM_ID_DWB_BLOCKS : (PRM_NAME_DWB_BLOCKS) default 2개
  if (double_write_buffer_size == 0 || num_blocks == 0)
    {
      /* Do not use double write buffer. */
      return NO_ERROR;
    }

  dwb_adjust_write_buffer_values (&double_write_buffer_size, &num_blocks);

  num_pages = double_write_buffer_size / IO_PAGESIZE;
  num_block_pages = num_pages / num_blocks;

// double_write_buffer_size = PRM_ID_DWB_SIZE : defualt 2M
// IO_PAGESIZE : MIN 4K, MAX 16K(default). 페이지 크기는 4K, 8K, 16K. 4K와 16K 사이의 값을 지정할 경우 지정한 값의 올림값으로 설정되며,
// 4K보다 작으면 4K로 설정되고 16K보다 크면 16K로 설정된다.

  assert (IS_POWER_OF_2 (num_blocks));
  assert (IS_POWER_OF_2 (num_pages));
  assert (IS_POWER_OF_2 (num_block_pages));
  assert (num_blocks <= DWB_MAX_BLOCKS);

  /* Create and open DWB volume first */
  vdes = fileio_format (thread_p, boot_db_full_name (), dwb_volume_name, LOG_DBDWB_VOLID, num_block_pages, true,
			false, false, IO_PAGESIZE, 0, false);
  if (vdes == NULL_VOLDES)
    {
      goto exit_on_error;
    }

  /* Needs to flush dirty page before activating DWB. */
  fileio_synchronize_all (thread_p, false);

  /* Create DWB blocks */
  error_code = dwb_create_blocks (thread_p, num_blocks, num_block_pages, &blocks);
  if (error_code != NO_ERROR)
    {
      goto exit_on_error;
    }

  dwb_Global.blocks = blocks;
  dwb_Global.num_blocks = num_blocks;
  dwb_Global.num_pages = num_pages;
  dwb_Global.num_block_pages = num_block_pages;
  dwb_Global.log2_num_block_pages = (unsigned int) (log ((float) num_block_pages) / log ((float) 2));
  dwb_Global.blocks_flush_counter = 0;
  dwb_Global.next_block_to_flush = 0;
  pthread_mutex_init (&dwb_Global.mutex, NULL);
  dwb_init_wait_queue (&dwb_Global.wait_queue);
  dwb_Global.vdes = vdes;
  dwb_Global.file_sync_helper_block = NULL;

  dwb_Global.slots_hashmap.init (dwb_slots_Ts, THREAD_TS_DWB_SLOTS, DWB_SLOTS_HASH_SIZE, freelist_block_size,
				 freelist_block_count, slots_entry_Descriptor);

  /* Set creation flag. */
  new_position_with_flags = DWB_RESET_POSITION (*current_position_with_flags);
  new_position_with_flags = DWB_STARTS_CREATION (new_position_with_flags);
// position_with_flags 를 초기화하고(? MSB에서 32bit, CREATE, MODIFY_STRUCTURE 를 제외한 flag 정리) CREATE bit 을 올린다.
  if (!ATOMIC_CAS_64 (&dwb_Global.position_with_flags, *current_position_with_flags, new_position_with_flags))
    {
      /* Impossible. */
      assert (false);
    }
  *current_position_with_flags = new_position_with_flags;

  return NO_ERROR;

exit_on_error:
  if (vdes != NULL_VOLDES)
    {
      fileio_dismount (thread_p, vdes);
      fileio_unformat (NULL, dwb_volume_name);
    }

  if (blocks != NULL)
    {
      for (i = 0; i < num_blocks; i++)
	{
	  dwb_finalize_block (&blocks[i]);
	}
      free_and_init (blocks);
    }

  return error_code;
}
```

### prm_get_integer_value

```cpp
#define PRM_IS_INTEGER(x)         ((x)->datatype == PRM_INTEGER)
#define PRM_IS_KEYWORD(x)         ((x)->datatype == PRM_KEYWORD)
#define PRM_GET_INT(x)      (*((int *) (x)))
/*
 * prm_get_integer_value () - get the value of a parameter of type integer
 *
 * return      : value
 * prm_id (in) : parameter id
 *
 * NOTE: keywords are stored as integers
 */
int
prm_get_integer_value (PARAM_ID prm_id)
{
  assert (prm_id <= PRM_LAST_ID);
  assert (PRM_IS_INTEGER (&prm_Def[prm_id]) || PRM_IS_KEYWORD (&prm_Def[prm_id]));

  return PRM_GET_INT (prm_get_value (prm_id));
}
/*
 * prm_get_value () - returns a pointer to the value of a system parameter
 *
 * return      : pointer to value
 * prm_id (in) : parameter id
 *
 * NOTE: for session parameters, in server mode, the value stored in
 *	 conn_entry->session_parameters is returned instead of the value
 *	 from prm_Def array.
 */
void *
prm_get_value (PARAM_ID prm_id)
{
#if defined (SERVER_MODE)
  THREAD_ENTRY *thread_p;

  assert (prm_id <= PRM_LAST_ID);

  if (PRM_SERVER_SESSION (prm_id) && BO_IS_SERVER_RESTARTED ())
    {
      SESSION_PARAM *sprm;
      thread_p = thread_get_thread_entry_info ();
      sprm = session_get_session_parameter (thread_p, prm_id);
      if (sprm)
	{
	  return &(sprm->value);
	}
    }

  return prm_Def[prm_id].value;
#else /* SERVER_MODE */
  assert (prm_id <= PRM_LAST_ID);

  return prm_Def[prm_id].value;
#endif /* SERVER_MODE */
}
```

### dwb_adjust_write_buffer_value

```cpp
/*
 * dwb_adjust_write_buffer_values () - Adjust double write buffer values.
 *
 * return   : Error code.
 * p_double_write_buffer_size (in/out) : Double write buffer size.
 * p_num_blocks (in/out): The number of blocks.
 *
 *  Note: The buffer size must be a multiple of 512 K. The number of blocks must be a power of 2.
 */
STATIC_INLINE void
dwb_adjust_write_buffer_values (unsigned int *p_double_write_buffer_size, unsigned int *p_num_blocks)
{
  unsigned int min_size;
  unsigned int max_size;

  assert (p_double_write_buffer_size != NULL && p_num_blocks != NULL
	  && *p_double_write_buffer_size > 0 && *p_num_blocks > 0);

  min_size = DWB_MIN_SIZE;
  max_size = DWB_MAX_SIZE;
// #define DWB_MIN_SIZE			    (512 * 1024)
// #define DWB_MAX_SIZE			    (32 * 1024 * 1024)

  if (*p_double_write_buffer_size < min_size)
    {
      *p_double_write_buffer_size = min_size;
    }
  else if (*p_double_write_buffer_size > min_size)
    {
      if (*p_double_write_buffer_size > max_size)
	{
	  *p_double_write_buffer_size = max_size;
	}
      else
	{
	  /* find smallest number multiple of 512 k */
	  unsigned int limit1 = min_size;

	  while (*p_double_write_buffer_size > limit1) // buffersize를 512K 의 2의 n승으로 맞추기위한 비교와 비트연산의 반복
	    {
	      assert (limit1 <= DWB_MAX_SIZE);
	      if (limit1 == DWB_MAX_SIZE)
		{
		  break;
		}
	      limit1 = limit1 << 1;
	    }

	  *p_double_write_buffer_size = limit1;
	}
    }

  min_size = DWB_MIN_BLOCKS;
  max_size = DWB_MAX_BLOCKS;
//#define DWB_MIN_BLOCKS			    1
//#define DWB_MAX_BLOCKS			    32

  assert (*p_num_blocks >= min_size);

  if (*p_num_blocks > min_size)
    {
      if (*p_num_blocks > max_size)
	{
	  *p_num_blocks = max_size;
	}
      else if (!IS_POWER_OF_2 (*p_num_blocks))
	{
	  unsigned int num_blocks = *p_num_blocks;

	  do
	    {
	      num_blocks = num_blocks & (num_blocks - 1);
	    }
	  while (!IS_POWER_OF_2 (num_blocks));

	  *p_num_blocks = num_blocks << 1;

	  assert (*p_num_blocks <= max_size);
	}
    }
}
//#define IS_POWER_OF_2(x)        (((x) & ((x) - 1)) == 0)
```

### fileio_format

```cpp
/*
 * fileio_format () - Format a volume of npages and mount the volume
 *   return: volume descriptor identifier on success, NULL_VOLDES on failure
 *   db_fullname(in): Name of the database where the volume belongs
 *   vlabel(in): Volume label
 *   volid(in): Volume identifier
 *   npages(in): Number of pages
 *   sweep_clean(in): Clean the newly formatted volume
 *   dolock(in): Lock the volume from other Unix processes
 *   dosync(in): synchronize the writes on the volume ?
 *   kbytes_to_be_written_per_sec : size to add volume per sec
 *
 * Note: If sweep_clean is true, every page is initialized with recovery
 *       information. In addition a volume can be optionally locked.
 *       For example, the active log volume is locked to prevent
 *       several server processes from accessing the same database.
 */
// fileio_format (thread_p, boot_db_full_name (), dwb_volume_name, LOG_DBDWB_VOLID, num_block_pages, true,
//			false, false, IO_PAGESIZE, 0, false);
int
fileio_format (THREAD_ENTRY * thread_p, const char *db_full_name_p, const char *vol_label_p, VOLID vol_id,
	       DKNPAGES npages, bool is_sweep_clean, bool is_do_lock, bool is_do_sync, size_t page_size,
	       int kbytes_to_be_written_per_sec, bool reuse_file)
{
  int vol_fd;
  FILEIO_PAGE *malloc_io_page_p;
  off_t offset;
  DKNPAGES max_npages;
#if !defined(WINDOWS)
  struct stat buf;
#endif
  bool is_raw_device = false;

  /* Check for bad number of pages...and overflow */
  if (npages <= 0)
    {
      er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_IO_FORMAT_BAD_NPAGES, 2, vol_label_p, npages);
      return NULL_VOLDES;
    }
// num_block_pages의 최소값이 1이고, DKNPAGES = 32INT, num_block_pages는 unsigned int이므로 오버플로우를 생각해서 0으로 정한 것 같다. 
  if (fileio_is_volume_exist (vol_label_p) == true && reuse_file == false)
    {
      /* The volume that we are trying to create already exist. Remove it and try again */
// vol_label_p = dwb_volume_name
#if !defined(WINDOWS)
      if (lstat (vol_label_p, &buf) != 0)
	{
	  er_set_with_oserror (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_IO_MOUNT_FAIL, 1, vol_label_p);
	}
// exist 로 파일 존재를 확인했지만 lstat 으로 file 정보를 받아오지 못했을때 에러
      if (!S_ISLNK (buf.st_mode))
	{
	  fileio_unformat (thread_p, vol_label_p);
	}
// S_ISLNK(buf.st_mode) : symbolic link가 아니면 file 을 지워버린다.
      else
	{
	  if (stat (vol_label_p, &buf) != 0)
	    {
	      er_set_with_oserror (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_IO_MOUNT_FAIL, 1, vol_label_p);
	    }
// symbolic link를 타고 원본 파일의 정보를 가져온다.
	  is_raw_device = S_ISCHR (buf.st_mode);
	}
// character device 이라면 is_raw_device 를 true 로 바꿔줌, 문자장치파일 : 스트림을 통하지 않고 디바이스에서 직접 처리하는 파일
// symbolic file 이면 남겨두는 이유가 무엇인지.
#else /* !WINDOWS */
      fileio_unformat (thread_p, vol_label_p);
      is_raw_device = false;
#endif /* !WINDOWS */
    }

  if (is_raw_device)
    {
      max_npages = (DKNPAGES) VOL_MAX_NPAGES (page_size);
    }// INTMAX
  else
    {
      max_npages = fileio_get_number_of_partition_free_pages (vol_label_p, page_size);
    } // 파일시스템의 블록 크기 * 여유 블록 / page_size 로 구한다. 파일이 존재하지 않을시 open으로 생성하고 close 하고 지운다.

  offset = FILEIO_GET_FILE_SIZE (page_size, npages - 1);
// off_t : singed long (파일의 크기를 나타내기 위해 사용, OS마다 다름, sys/types.h 에서 정의)
  /*
   * Make sure that there is enough pages on the given partition before we
   * create and initialize the volume.
   * We should also check for overflow condition.
   */
  if (npages > max_npages || (offset < npages && npages > 1))
    {
      if (offset < npages)
	{
	  /* Overflow */
	  offset = FILEIO_GET_FILE_SIZE (page_size, VOL_MAX_NPAGES (page_size));
	}
      if (max_npages >= 0)
	{
	  er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_IO_FORMAT_OUT_OF_SPACE, 5, vol_label_p, npages, (offset / 1024),
		  max_npages, FILEIO_GET_FILE_SIZE (page_size / 1024, max_npages));
	}
      else
	{
	  /* There was an error in fileio_get_number_of_partition_free_pages */
	  ;
	}

      return NULL_VOLDES;
    }
// max_npages 가 파일시스템의 최대 여유크기이니 npages가 크면
// 할당할 수 있는 양보다 원하는 할당 크기가 큰것이고
// offset 이 npages 보다 작으면 오버플로우이다.
  malloc_io_page_p = (FILEIO_PAGE *) malloc (page_size);
  if (malloc_io_page_p == NULL)
    {
      er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_OUT_OF_VIRTUAL_MEMORY, 1, page_size);
      return NULL_VOLDES;
    }
// 페이지 한개 할당.
  memset ((char *) malloc_io_page_p, 0, page_size);
  (void) fileio_initialize_res (thread_p, malloc_io_page_p, (PGLENGTH) page_size);
// 페이지 초기화
  vol_fd = fileio_create (thread_p, db_full_name_p, vol_label_p, vol_id, is_do_lock, is_do_sync);
// open(O_RDWR | O_CREATE, 0600)
  FI_TEST (thread_p, FI_TEST_FILE_IO_FORMAT, 0);
// #define FI_TEST(th, code, state) 	fi_test(th, code, NULL, state, ARG_FILE_LINE) __FILE__, __LINE__ 과정이 잘 진행되고 있는지 TEST
  if (vol_fd != NULL_VOLDES)
    {
      /* initialize the pages of the volume. */

      /* initialize at least two pages, the header page and the last page. in case of is_sweep_clean == true, every
       * page of the volume will be written. */

      if (fileio_write_or_add_to_dwb (thread_p, vol_fd, malloc_io_page_p, 0, page_size) == NULL)
	{
	  fileio_dismount (thread_p, vol_fd);
	  fileio_unformat (thread_p, vol_label_p);
	  free_and_init (malloc_io_page_p);

	  if (er_errid () != ER_INTERRUPTED)
	    {
	      er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_IO_WRITE, 2, 0, vol_id);
	    }

	  vol_fd = NULL_VOLDES;
	  return vol_fd;
	}
// page를 dwb volume에 쓴다. malloc_io_page_p 는 빈 페이지이고 메모리만 할당되어있는데 어떻게 쓰이는지 궁금하다. 
//  FILEIO_PAGE * 를 void *io_page_p 로 받아 write(vol_fd, io_page_p, page_size) 로 입력한다.
// write 가 정상 작동하는지 파일이 생성됐는지 테스트 하는 것 같다.
#if defined(HPUX)
      if ((is_sweep_clean == true
	   && !fileio_initialize_pages (vol_fd, malloc_io_page_p, npages, page_size, kbytes_to_be_written_per_sec))
	  || (is_sweep_clean == false
	      && !fileio_write (vol_fd, malloc_io_page_p, npages - 1, page_size, FILEIO_WRITE_DEFAULT_WRITE)))
#else /* HPUX */
      if (!((fileio_write_or_add_to_dwb (thread_p, vol_fd, malloc_io_page_p, npages - 1, page_size) == malloc_io_page_p)
	    && (is_sweep_clean == false
		|| fileio_initialize_pages (thread_p, vol_fd, malloc_io_page_p, 0, npages, page_size,
					    kbytes_to_be_written_per_sec) == malloc_io_page_p)))
#endif /* HPUX */
	{
	  /* It is likely that we run of space. The partition where the volume was created has been used since we
	   * checked above. */

	  max_npages = fileio_get_number_of_partition_free_pages (vol_label_p, page_size);

	  fileio_dismount (thread_p, vol_fd);
	  fileio_unformat (thread_p, vol_label_p);
	  free_and_init (malloc_io_page_p);
	  if (er_errid () != ER_INTERRUPTED)
	    {
	      er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_IO_FORMAT_OUT_OF_SPACE, 5, vol_label_p, npages,
		      (offset / 1024), max_npages, (long long) ((page_size / 1024) * max_npages));
	    }
	  vol_fd = NULL_VOLDES;
	  return vol_fd;
	}
// is_sweep_clean = 1로 들어왔으니 fileio_initialize_pages(interupt 체크 fileio_write_or_add_to_dwb로 write 실패하면 밑의 error 발생)
#if defined(WINDOWS)
      fileio_dismount (thread_p, vol_fd);
      vol_fd = fileio_mount (thread_p, NULL, vol_label_p, vol_id, false, false);
// fileio_create로 만들었던 볼륨이라 dismount 하고 다시 mount 한다. 두개의 차이는 mount는 생성하고 fileio_set_permission 같은 몇가지 함수로 초기화한다.
#endif /* WINDOWS */
    }
  else
    {
      er_set_with_oserror (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_BO_CANNOT_CREATE_VOL, 2, vol_label_p, db_full_name_p);
    }

  free_and_init (malloc_io_page_p);
// malloc_io_page_p free 하고 pointer 를 0 으로 초기화
  return vol_fd;
}
```

### fileio_synchronize_all

```cpp
/*
 * fileio_synchronize_all () - Synchronize all database volumes with disk
 *   return:
 *   include_log(in):
 */
int
fileio_synchronize_all (THREAD_ENTRY * thread_p, bool is_include)
{
  int success = NO_ERROR;
  bool all_sync = false;
  APPLY_ARG arg = { 0 };
#if defined (SERVER_MODE) || defined (SA_MODE)
  PERF_UTIME_TRACKER time_track;

  PERF_UTIME_TRACKER_START (thread_p, &time_track);
#endif /* defined (SERVER_MODE) || defined (SA_MODE) */
// 시간기록
  arg.vol_id = NULL_VOLID;

  er_stack_push ();
// stack_block 에 er_message push
  if (is_include)
    {
      /* Flush logs. */
      (void) fileio_traverse_system_volume (thread_p, fileio_synchronize_sys_volume, &arg);
    }

#if !defined (CS_MODE)
  /* Flush DWB before volume data. */
  success = dwb_flush_force (thread_p, &all_sync);
#endif
// !IS_CREATE 플레그에 걸려 all_sync 만 true 로 바뀜 시간기록 다시 시작 success에는 NO_ERROR 반환
  /* Check whether the volumes were flushed. */
  if (success == NO_ERROR && all_sync == false)
    {
      /* Flush volume data. */
      (void) fileio_traverse_permanent_volume (thread_p, fileio_synchronize_volume, &arg);

      if (er_errid () == ER_IO_SYNC)
	{
	  success = ER_FAILED;
	}
    }

  er_stack_pop ();
// stack_block 에 push 했던 er_message 다시 pop
#if defined (SERVER_MODE) || defined (SA_MODE)
  PERF_UTIME_TRACKER_TIME (thread_p, &time_track, PSTAT_FILE_IOSYNC_ALL);
#endif /* defined (SERVER_MODE) || defined (SA_MODE) */

  return success;
}
```

### dwb_create_blocks

```cpp
/*
 * dwb_create_blocks () - Create the blocks.
 *
 * return   : Error code.
 * thread_p (in) : The thread entry.
 * num_blocks(in): The number of blocks.
 * num_block_pages(in): The number of block pages.
 * p_blocks(out): The created blocks.
 */
STATIC_INLINE int
dwb_create_blocks (THREAD_ENTRY * thread_p, unsigned int num_blocks, unsigned int num_block_pages,
		   DWB_BLOCK ** p_blocks)
{
  DWB_BLOCK *blocks = NULL;
  char *blocks_write_buffer[DWB_MAX_BLOCKS];
  FLUSH_VOLUME_INFO *flush_volumes_info[DWB_MAX_BLOCKS];
  DWB_SLOT *slots[DWB_MAX_BLOCKS];
  unsigned int block_buffer_size, i, j;
  int error_code;
  FILEIO_PAGE *io_page;

  assert (num_blocks <= DWB_MAX_BLOCKS);

  *p_blocks = NULL;

  for (i = 0; i < DWB_MAX_BLOCKS; i++)
    {
      blocks_write_buffer[i] = NULL;
      slots[i] = NULL;
      flush_volumes_info[i] = NULL;
    }

  blocks = (DWB_BLOCK *) malloc (num_blocks * sizeof (DWB_BLOCK));
  if (blocks == NULL)
    {
      er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_OUT_OF_VIRTUAL_MEMORY, 1, num_blocks * sizeof (DWB_BLOCK));
      error_code = ER_OUT_OF_VIRTUAL_MEMORY;
      goto exit_on_error;
    }
  memset (blocks, 0, num_blocks * sizeof (DWB_BLOCK));
// blocks 메모리할당 및 초기화, 블록 생성과 초기화 
  block_buffer_size = num_block_pages * IO_PAGESIZE;
// double_write_buffer_size / num_blocks
  for (i = 0; i < num_blocks; i++)
    {
      blocks_write_buffer[i] = (char *) malloc (block_buffer_size * sizeof (char));
      if (blocks_write_buffer[i] == NULL)
	{
	  er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_OUT_OF_VIRTUAL_MEMORY, 1, block_buffer_size * sizeof (char));
	  error_code = ER_OUT_OF_VIRTUAL_MEMORY;
	  goto exit_on_error;
	}
      memset (blocks_write_buffer[i], 0, block_buffer_size * sizeof (char));
    }
// blocks_write_buffer 에 block의 크기만큼 할당 블록당 1개씩 갖는 느낌, block_write_buffer 생성
// 각 Block에서 지역변수 write_buffer라는 포인터를 가지고 있다. 블록 내 모든 Slot들이 참조하여 실제 Page의 내용이 저장된다. << 분석문서 설명글
// 왜 void * 형이 아닌 char * 을 썻을지 궁금하다.(무슨 이유가 있는지)
  for (i = 0; i < num_blocks; i++)
    {
      slots[i] = (DWB_SLOT *) malloc (num_block_pages * sizeof (DWB_SLOT));
      if (slots[i] == NULL)
	{
	  er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_OUT_OF_VIRTUAL_MEMORY, 1, num_block_pages * sizeof (DWB_SLOT));
	  error_code = ER_OUT_OF_VIRTUAL_MEMORY;
	  goto exit_on_error;
	}
      memset (slots[i], 0, num_block_pages * sizeof (DWB_SLOT));
    }
// block 1개의 page 개수만큼 SLOT 생성 및 초기화
  for (i = 0; i < num_blocks; i++)
    {
      flush_volumes_info[i] = (FLUSH_VOLUME_INFO *) malloc (num_block_pages * sizeof (FLUSH_VOLUME_INFO));
      if (flush_volumes_info[i] == NULL)
	{
	  er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_OUT_OF_VIRTUAL_MEMORY, 1,
		  num_block_pages * sizeof (FLUSH_VOLUME_INFO));
	  error_code = ER_OUT_OF_VIRTUAL_MEMORY;
	  goto exit_on_error;
	}
      memset (flush_volumes_info[i], 0, num_block_pages * sizeof (FLUSH_VOLUME_INFO));
    }
// flush_volumes_info 는 vdes, volume 에 flush 할 페이지의 수, 모든 페이지가 쓰였는지 여부, flush status 등을 담고있다.
// 각 블록의 페이지수만큼 할당하고 초기화한다.
  for (i = 0; i < num_blocks; i++)
    {
      /* No need to initialize FILEIO_PAGE header here, since is overwritten before flushing */
      for (j = 0; j < num_block_pages; j++)
	{
	  io_page = (FILEIO_PAGE *) (blocks_write_buffer[i] + j * IO_PAGESIZE);
// buffer의 각 블록의 페이지마다의 point 를 io_page 에 저장
	  fileio_initialize_res (thread_p, io_page, IO_PAGESIZE);
// io_page 초기화 LOG_LSA의 값은 null 로, pageid, volid -1 로 초기화한다.
	  dwb_initialize_slot (&slots[i][j], io_page, j, i);
// i = block_no, j = position_in_blocks, slot 의 VPID, LOG_LSA 생성 및 초기화
	}

      dwb_initialize_block (&blocks[i], i, 0, blocks_write_buffer[i], slots[i], flush_volumes_info[i], 0,
			    num_block_pages);
    }
// block 의 초기화 flush_volumes_info, count_flush_volumes_info = 0 (현재 flush 할 볼륨의 수)
// max_to_flush_vdes (flush 할 수 있는 최대 개수 = num_block_pages), write_buffer, slots, dwb_wait_queue
// count_wb_pages = 0  (Count DWB pages 라는데 뭔지 모르겠다.), block_no, version = 0, all_pages_written = false; 로 초기화한다.
  *p_blocks = blocks;

  return NO_ERROR;

exit_on_error:
  for (i = 0; i < DWB_MAX_BLOCKS; i++)
    {
      if (slots[i] != NULL)
	{
	  free_and_init (slots[i]);
	}

      if (blocks_write_buffer[i] != NULL)
	{
	  free_and_init (blocks_write_buffer[i]);
	}

      if (flush_volumes_info[i] != NULL)
	{
	  free_and_init (flush_volumes_info[i]);
	}
    }

  if (blocks != NULL)
    {
      free_and_init (blocks);
    }

  return error_code;
}
```
