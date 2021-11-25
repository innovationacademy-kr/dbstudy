## dwb_Global
```cpp
/* The double write buffer structure. */
typedef struct double_write_buffer DOUBLE_WRITE_BUFFER;
struct double_write_buffer
{
  DWB_BLOCK *blocks;		/* block array */
  unsigned int num_blocks;	/* The total number of blocks */
  unsigned int num_pages;	/* The total number of pages */
  unsigned int num_block_pages;	/* The number of pages in a block */
  
  pthread_mutex_t mutex;	/* The mutex to protect the wait queue. */
  DWB_WAIT_QUEUE wait_queue;	/* The wait queue, used when the DWB structure changed. */

  UINT64 volatile position_with_flags;	/* The current position in double write buffer and flags. Flags keep the
					 * state of each block (started, ended), create DWB status, modify DWB status.
					 */
					 
		 ...
};

/* DWB. */
static DOUBLE_WRITE_BUFFER dwb_Global;
```

<br/>

## position_with_flags

```cpp
00000000 00000000 00000000 00000000  00001000 00000000 00000000 00000000 : DWB_MODIFY_STRUCTURE
00000000 00000000 00000000 00000000  00000100 00000000 00000000 00000000 : DWB_CREATE
```

<br/>


## 몇가지 함수들

### ATOMIC_INC_64
```cpp
template <typename T, typename V> inline T ATOMIC_INC_64 (volatile T *ptr, V amount)
{
  static_assert (sizeof (T) == sizeof (UINT64), "Not 64bit");
#if defined (_WIN64)
  return (T) InterlockedExchangeAdd64 (reinterpret_cast <volatile INT64 *>(ptr), amount) + amount;
#elif defined(WINDOWS)
  return win32_exchange_add64 (reinterpret_cast <volatile UINT64 *>(ptr), amount) + amount;
#else
  return __sync_add_and_fetch (ptr, amount);
#endif
}
```

```cpp
T __sync_add_and_fetch (T* __p, U __v, ...);
```

<br/>

### ATOMIC_CAS_64
```cpp
template <typename T, typename V1, typename V2> inline bool ATOMIC_CAS_64 (volatile T *ptr, V1 cmp_val, V2 swap_val)
{
  static_assert (sizeof (T) == sizeof (UINT64), "Not 64bit");
#if defined (_WIN64)
  return InterlockedCompareExchange64 (reinterpret_cast <volatile INT64 *>(ptr), swap_val, cmp_val) == cmp_val;
#elif defined(WINDOWS)
  return win32_compare_exchange64 (reinterpret_cast <volatile UINT64 *>(ptr), swap_val, cmp_val) == cmp_val;
#else
  return __sync_bool_compare_and_swap (ptr, cmp_val, swap_val);
#endif
}
```

```cpp
bool __sync_bool_compare_and_swap (T* __p, U __compVal, V __exchVal, ...);
```

<br/>

### ATOMIC_TAS_64
```cpp
template <typename T, typename V> inline T ATOMIC_TAS_64 (volatile T *ptr, V amount)
{
  static_assert (sizeof (T) == sizeof (UINT64), "Not 64bit");
#if defined (_WIN64)
  return (T) InterlockedExchange64 (reinterpret_cast <volatile INT64 *>(ptr), (__int64) amount);
#elif defined(WINDOWS)
  return win32_exchange64 (reinterpret_cast <volatile UINT64 *>(ptr), amount);
#else
  return __sync_lock_test_and_set (ptr, amount);
#endif
}
```
### ATOMIC_TAS_ADDR
```cpp
template <typename T> inline T *ATOMIC_TAS_ADDR (T * volatile *ptr, T *new_val)
{
#if defined (WINDOWS)
  return static_cast <T *>(InterlockedExchangePointer (reinterpret_cast <volatile PVOID *>(ptr), new_val));
#else
  return __sync_lock_test_and_set (ptr, new_val);
#endif
}
```

```cpp
T __sync_lock_test_and_set (T* __p, U __v, ...);
```

<br/>


## 진입점

```cpp
dwb_create (thread_p, log_path, log_prefix)
=> boot_create_all_volumes
=> xboot_initialize_server
=> boot_initialize_server
=> boot_initialize_client
=> db_init
=> createdb
```

```cpp
/* Create double write buffer if not already created. DWB creation must be done before first volume.
 * DWB file is created on log_path.
 */
if (dwb_create(thread_p, log_path, log_prefix) != NO_ERROR)
{
  goto error;
}
```


<br/>

## dwb_create

*storage/double_write_buffer.c: 2820*

```cpp
/*
 * dwb_create () - Create DWB.
 *
 * return   : Error code.
 * thread_p (in): The thread entry.
 * dwb_path_p (in) : The double write buffer volume path.
 * db_name_p (in) : The database name.
 */
int dwb_create(THREAD_ENTRY *thread_p, const char *dwb_path_p, const char *db_name_p)
{
  UINT64 current_position_with_flags;
  int error_code = NO_ERROR;

  error_code = dwb_starts_structure_modification(thread_p, &current_position_with_flags);
>> 구조 변경 시작, bit 플래그 세팅, dwb 초기화

  if (error_code != NO_ERROR)
  {
    dwb_log_error("Can't create DWB: error = %d\n", error_code);
    return error_code;
  }

  /* DWB structure modification started, no other transaction can modify the global position with flags */
  if (DWB_IS_CREATED(current_position_with_flags))
  {
    /* Already created, restore the modification flag. */
    goto end;
  }

  fileio_make_dwb_name(dwb_Volume_name, dwb_path_p, db_name_p);
> 만약 dwb_path_p가 /로 끝나는 경우
> *dwb_Volume_name = "[dwb_path_p][db_name_p]_dwb";
> /가 없는 경우
> *dwb_Volume_name = "[dwb_path_p]/[db_name_p]_dwb";

  error_code = dwb_create_internal(thread_p, dwb_Volume_name, &current_position_with_flags);
>> 설명하지 않음
  if (error_code != NO_ERROR)
  {
    dwb_log_error("Can't create DWB: error = %d\n", error_code);
    goto end;
  }

end:
  /* Ends the modification, allowing to others to modify global position with flags. */
  dwb_ends_structure_modification(thread_p, current_position_with_flags);
>> 구조 변경 종료, bit 플래그 세팅, 이 스레드의 점유 상태를 해제하고 wait_queue에 있는 다음 스레드를 깨움

  return error_code;
}
```

<br/>

## dwb_starts_structure_modification

*storage/double_write_buffer.c: 806*

```cpp
/*
 * dwb_starts_structure_modification () - Starts structure modifications.
 *
 * return   : Error code
 * thread_p (in): The thread entry.
 * current_position_with_flags(out): The current position with flags.
 *
 *  Note: This function must be called before changing structure of DWB.
 */
STATIC_INLINE int
dwb_starts_structure_modification (THREAD_ENTRY * thread_p, UINT64 * current_position_with_flags)
{
  UINT64 local_current_position_with_flags, new_position_with_flags, min_version;
  unsigned int block_no;
  int error_code = NO_ERROR;
  unsigned int start_block_no, blocks_count;
  DWB_BLOCK *file_sync_helper_block;

  assert (current_position_with_flags != NULL);

  do
    {
      local_current_position_with_flags = ATOMIC_INC_64 (&dwb_Global.position_with_flags, 0ULL);
>>>   local_current_position_with_flags = dwb_Global.position_with_flags;

      if (DWB_IS_MODIFYING_STRUCTURE (local_current_position_with_flags))
>     만약 local_current_position_with_flags 에 DWB_MODIFY_STRUCTURE 플래그가 세워져있다면
	{
	  /* 오직 하나의 스레드만 구조체에 영향을 줄 수 있기 때문에 에러처리 */
	  return ER_FAILED;
	}

      new_position_with_flags = DWB_STARTS_MODIFYING_STRUCTURE (local_current_position_with_flags);
>     DWB_MODIFY_STRUCTURE 플래그를 set

      /* Start structure modifications, the threads that want to flush afterwards, have to wait. */
    }
  while (!ATOMIC_CAS_64 (&dwb_Global.position_with_flags, local_current_position_with_flags, new_position_with_flags));
> dwb_Global.position_with_flags 값과 local_current_position_with_flags값이 같으면,
  dwb_Global.position_with_flag에 new_position_with_flags를 할당하고 true를 반환
> 같지 않으면 false를 반환

> 아마도 다른 스레드가 위 코드를 거의 동시에 시작한 경우,
  while 에 늦게 도착한 스레드는 코드를 다시 실행하고 DWB_MODIFY_STRUCTURE 플래그가 세워져 있기 때문에 에러처리


#if defined(SERVER_MODE)
  while ((ATOMIC_INC_32 (&dwb_Global.blocks_flush_counter, 0) > 0)
	 || dwb_flush_block_daemon_is_running () || dwb_file_sync_helper_daemon_is_running ())
>>> while (dwb_Global.blocks_flush_counter > 0
	 || dwb_flush_block_daemon_is_running() || dwb_file_sync_helper_daemon_is_running())
> flush thread가 dwb에 접근 중일 때는 구조를 변경할 수 없으므로 flush가 끝날 때까지 대기
    {
      /* Can't modify structure while flush thread can access DWB. */
      thread_sleep (20);
    }
#endif

  /* Since we set the modify structure flag, I'm the only thread that access the DWB. */
  file_sync_helper_block = dwb_Global.file_sync_helper_block;
  if (file_sync_helper_block != NULL)
    {
      /* All remaining blocks are flushed by me. */
      (void) ATOMIC_TAS_ADDR (&dwb_Global.file_sync_helper_block, (DWB_BLOCK *) NULL);
>>>   dwb_Global.file_sync_helper_block = NULL;

      dwb_log ("Structure modification, needs to flush DWB block = %d having version %lld\n",
	       file_sync_helper_block->block_no, file_sync_helper_block->version);
    }

  local_current_position_with_flags = ATOMIC_INC_64 (&dwb_Global.position_with_flags, 0ULL);
>>> local_current_position_with_flags = dwb_Global.position_with_flags

  /* Need to flush incomplete blocks, ordered by version. */
  start_block_no = DWB_NUM_TOTAL_BLOCKS;
  min_version = 0xffffffffffffffff;
> 어떤 block의 version 보다 무조건 크도록 설정

  blocks_count = 0;
  for (block_no = 0; block_no < DWB_NUM_TOTAL_BLOCKS; block_no++)
    {
      if (DWB_IS_BLOCK_WRITE_STARTED (local_current_position_with_flags, block_no))
>     MSB 부터 정방향으로 체크
	{
	  if (dwb_Global.blocks[block_no].version < min_version)
	    {
	      min_version = dwb_Global.blocks[block_no].version;
	      start_block_no = block_no;
	    }
	  blocks_count++;
	}
    }
    
> DWB_IS_BLOCK_WRITE_STARTED(local_current_position_with_flags, block_no)
       = (local_current_position_with_flags) & (1ULL << (63 - (block_no)))) != 0
> local_current_position_with_flags 에서 오른쪽 방향으로 block_no 번째 bit가 set되어 있으면 true, clear되어있으면 false를 반환
 
    
  block_no = start_block_no;
  while (blocks_count > 0)
    {
      if (DWB_IS_BLOCK_WRITE_STARTED (local_current_position_with_flags, block_no))
>     위와 같음. 오른쪽 방향으로 block_no 번째 비트가 set되어있으면 
	{
	  /* Flush all pages from current block. I must flush all remaining data. */
	  error_code =
	    dwb_flush_block (thread_p, &dwb_Global.blocks[block_no], false, &local_current_position_with_flags);
>        블록에 남아있는 데이터 flush
	  if (error_code != NO_ERROR)
	    {
	      /* Something wrong happened. */
	      dwb_log_error ("Can't flush block = %d having version %lld\n", block_no,
			     dwb_Global.blocks[block_no].version);

	      return error_code;
	    }

	  dwb_log_error ("DWB flushed %d block having version %lld\n", block_no, dwb_Global.blocks[block_no].version);
	  blocks_count--;
>         flush 이후 flush 가 필요한 블록 카운트 -1
	}

      block_no = (block_no + 1) % DWB_NUM_TOTAL_BLOCKS;
>     결과적으로 version이 가장 낮은 블록부터 오른쪽으로 순회, 인덱스 끝에 닿으면 다시 0으로 돌아와서 순회.
    }

  local_current_position_with_flags = ATOMIC_INC_64 (&dwb_Global.position_with_flags, 0ULL);
>>> local_current_position_with_flags = dwb_Global.position_with_flags

  assert (DWB_GET_BLOCK_STATUS (local_current_position_with_flags) == 0);
> flush에 실패한 block이 있을 경우, crash

  *current_position_with_flags = local_current_position_with_flags;
> 포인터 매개변수를 통해 out

  return NO_ERROR;
}
```
