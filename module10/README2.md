## DWB Flag

```cpp
typedef struct double_write_buffer DOUBLE_WRITE_BUFFER;
struct double_write_buffer
{
  unsigned int num_blocks;
> 블록의 전체 개수
  
  unsigned int num_pages;
> 페이지의 전체 개수
  
  unsigned int num_block_pages;
> 블록당 페이지 수
  
  unsigned int log2_num_block_pages;
> log2(블록당 페이지 수)

  pthread_mutex_t mutex;
> wait queue 변경 시 사용될 lock
  DWB_WAIT_QUEUE wait_queue;
> wait queue

  UINT64 volatile position_with_flags;
}
```

<br />

### log2_num_block_pages

num_blocks(블록의 전체 개수) 와 num_pages(페이지의 전체 개수) 는 모두 2^n
<br />

```cpp
IO_PAGESIZE = 16 KB 기준

32 <= num_pages <= 2048
32 <= 2^(5~11) <= 2048

1 <= num_blocks <= 32
1 <= 2^(0~5) <= 32


num_block_pages = num_pages(2^a) / num_blocks(2^b)
```
<br />
따라서 num_block_pages는 2^n (n >= 0) 이 됩니다.<br />
때문에 log2_num_block_pages는 n (n >= 0) 이 됩니다.<br />
<br />
2진수에서 값이 2^n라는 것은 하나의 비트만 SET 되어있다는 것을 의미합니다.<br />
따라서 log2_num_block_pages 만큼 비트를 미는 것으로 깔끔하게 쓰고잇는 현재 블록을 얻을 수 있습니다.<br />
<br />

```
값이 64인 변수를 예로 들면

log2 64 = 6

64:
0100 0000

64 >> log2 64 = 0000 0001
```


<br />

### position_with_flags

![제목 없음-2](https://user-images.githubusercontent.com/12230655/145351207-081b679b-6284-48e4-b88a-b574a628ba53.png)

<br />
<br />
<br />

## dwb_set_data_on_next_slot

### 진입점

```cpp
dwb_set_data_on_next_slot (thread_p, io_page_p, can_wait, p_dwb_slot)
=> dwb_add_page
=> pgbuf_bcb_flush_with_wal 또는 fileio_write_or_add_to_dwb 또는 dwb_flush_force
```

```cpp
dwb_set_data_on_next_slot (thread_p, io_page_p, can_wait, p_dwb_slot)
=> pgbuf_bcb_flush_with_wal
```

<br />

### dwb_set_data_on_next_slot


```cpp
현재 슬롯을 반환해 값을 넣고 다음 슬롯이 있다면 다음 슬롯을 물려줌

return         : 에러 코드
io_page_p      : 슬롯에 놓게 될 데이터
can_wait       : 처리 도중 대기가 허용되는 지. true이면 허용
p_dwb_slot     : 슬롯 포인터의 포인터
```
 
```cpp
int
dwb_set_data_on_next_slot (THREAD_ENTRY * thread_p, FILEIO_PAGE * io_page_p, bool can_wait, DWB_SLOT ** p_dwb_slot)
{
  int error_code;

  assert (p_dwb_slot != NULL && io_page_p != NULL);

  error_code = dwb_acquire_next_slot (thread_p, can_wait, p_dwb_slot);
> 페이지를 놓을 슬롯을 찾아 *p_dwb_slot 에 넣어줍니다

  if (error_code != NO_ERROR)
    {
      return error_code;
    }

  assert (can_wait == false || *p_dwb_slot != NULL);
> can_wait가 false 이거나,
> can_wait가 true이면서 *p_dwb_slot이 NULL은 아니어야 함
  
  if (*p_dwb_slot == NULL)
    {
      return NO_ERROR;
    }
> can_wait가 false이고, *p_dwb_slot이 NULL인 경우 처리에 사용할 슬롯을 찾을 수 없었던 것이므로 종료


  dwb_set_slot_data (thread_p, *p_dwb_slot, io_page_p);
> 찾은 슬롯에 페이지 놓기

  return NO_ERROR;
}
```

<br />
<br />

### dwb_acquire_next_slot

```cpp
값을 넣을 슬롯을 가져옵니다

return         : 에러 코드
can_wait       : 처리 도중 대기가 허용되는 지. true이면 허용
p_dwb_slot     : 슬롯 포인터의 포인터
```

```cpp
STATIC_INLINE int
dwb_acquire_next_slot (THREAD_ENTRY * thread_p, bool can_wait, DWB_SLOT ** p_dwb_slot)
{
  UINT64 current_position_with_flags, current_position_with_block_write_started, new_position_with_flags;
  unsigned int current_block_no, position_in_current_block;
  int error_code = NO_ERROR;
  DWB_BLOCK *block;

  assert (p_dwb_slot != NULL);
  *p_dwb_slot = NULL;

start:
> 시작점

  current_position_with_flags = ATOMIC_INC_64 (&dwb_Global.position_with_flags, 0ULL);
> current_position_with_flags = dwb_Global.position_with_flags

  if (DWB_NOT_CREATED_OR_MODIFYING (current_position_with_flags))
> dwb가 만들어지지 않았고, 만들어지는 중이라면
    {
      /* Rarely happens. */
      if (DWB_IS_MODIFYING_STRUCTURE (current_position_with_flags))
> 만들어지는 중이라면
	{
	  if (can_wait == false)
> (dwb가 만들어질 때까지) 대기가 불가능하다면
	    {
	      return NO_ERROR;
> 종료
	    }

	  error_code = dwb_wait_for_strucure_modification (thread_p);
> dwb 가 만들어질 때까지 대기
	  
	  if (error_code != NO_ERROR)
> 에러 발생
	    {
	      if (error_code == ER_CSS_PTHREAD_COND_TIMEDOUT)
		{
		  goto start;
> 타임아웃일 경우 위에서부터 재시도
		}
	      return error_code;
> 다른 에러일 경우 에러 반환
	    }

	  goto start;
> 다시 제일 위 조건부터 플래그 검증
	}
      else if (!DWB_IS_CREATED (current_position_with_flags))
> 만들어지지 않았으면
	{
	  if (DWB_IS_ANY_BLOCK_WRITE_STARTED (current_position_with_flags))
> 블록이 하나라도 WRITE_STARTED 상태라면 (0~31 번째 비트 중 하나라도 SET 이라면)

	    {
	      /* Someone deleted the DWB, before flushing the data. */
	      er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_DWB_DISABLED, 0);
	      return ER_DWB_DISABLED;
> 에러처리
	    }

	  /* Someone deleted the DWB */
	  return NO_ERROR;
> DWB 가 사용불가하므로 종료
	}
      else
	{
	  assert (false);
	}
    }

  current_block_no = DWB_GET_BLOCK_NO_FROM_POSITION (current_position_with_flags);
> current_block_no = (current_position_with_flags & DWB_POSITION_MASK) >> dwb_Global.log2_num_block_pages

  position_in_current_block = DWB_GET_POSITION_IN_BLOCK (current_position_with_flags);
> position_in_current_block = current_position_with_flags & DWB_POSITION_MASK & (dwb_Global.num_block_pages - 1)


ex)
num_block_pages: 64
log2_num_block_pages: 6

current_position_with_flags & DWB_POSITION_MASK 을 통해 block 번호와 slot index를 알아낼 수 있음
해당 값이 0 이면 블록 번호 0 // 64 = 0, 슬롯 인덱스 0 % 64 = 0
해당 값이 65 이면 블록 번호 65 // 64 = 1, 슬롯 인덱스 65 % 64 = 1

이 과정을 비트로 나타내면 아래와 같습니다

current_position_with_flags & DWB_POSITION_MASK => 1이라고 가정 => 00 0000 0000 0000 0000 0000 0000 0001
블록 번호: 0000 0001 >> 6 = 0
슬롯 인덱스: 0000 0001 & 63 = 0000 0001 & 0011 1111 = 1

current_position_with_flags & DWB_POSITION_MASK => 65라고 가정 => 00 0000 0000 0000 0000 0000 0100 0001
블록 번호: 0100 0001 >> 6 = 1
슬롯 인덱스: 0100 0001 & 0011 1111 = 1



  assert (current_block_no < DWB_NUM_TOTAL_BLOCKS && position_in_current_block < DWB_BLOCK_NUM_PAGES);

  if (position_in_current_block == 0)
> 처리하게 될 슬롯이 0번째 슬롯일 때
    {
      /* This is the first write on current block. Before writing, check whether the previous iteration finished. */
      if (DWB_IS_BLOCK_WRITE_STARTED (current_position_with_flags, current_block_no))
> current_position_with_flags의 MSB에서 current_block_no 번째 비트가 SET 되어 있으면 =
> current_block_no 블록이 쓰기 작업 중이면
	{
	  if (can_wait == false)
	    {
	      return NO_ERROR;
> 대기가 불가능하면 종료
	    }

	  dwb_log ("Waits for flushing block=%d having version=%lld) \n",
		   current_block_no, dwb_Global.blocks[current_block_no].version);


	  error_code = dwb_wait_for_block_completion (thread_p, current_block_no);
> 버퍼가 덮어씌워지는 것을 피하기 위해서 이전 쓰기 작업이 끝날 때까지 대기
> dwb_wait_for_strucure_modification 와 체크 플래그만 다르고 나머진 동일

	  if (error_code != NO_ERROR)
	    {
	      if (error_code == ER_CSS_PTHREAD_COND_TIMEDOUT)
		{
		  goto start;
> timeout의 경우 처음부터 재시도
		}

	      dwb_log_error ("Error %d while waiting for flushing block=%d having version %lld \n",
			     error_code, current_block_no, dwb_Global.blocks[current_block_no].version);
	      return error_code;
> 다른 에러의 경우 에러처리
	    }

	  goto start;
> 대기가 끝난 이후 플래그 검토를 위해 처음부터 시작
	}

      assert (!DWB_IS_BLOCK_WRITE_STARTED (current_position_with_flags, current_block_no));

      current_position_with_block_write_started =
	DWB_STARTS_BLOCK_WRITING (current_position_with_flags, current_block_no);
> current_position_with_block_write_started = current_position_with_flags의 MSB에서 current_block_no 번째 비트를 SET

      new_position_with_flags = DWB_GET_NEXT_POSITION_WITH_FLAGS (current_position_with_block_write_started);
> new_position_with_flags = slot의 index가 (num_pages - 1) 과 같다면 0, 아니라면 slot을 1 증가하고 플래그를 반환합니다
> 위 방식으로 슬롯을 순회합니다

    }
  else
    {
      assert (DWB_IS_CREATED (dwb_Global.position_with_flags));
      assert (!DWB_IS_MODIFYING_STRUCTURE (dwb_Global.position_with_flags));

      new_position_with_flags = DWB_GET_NEXT_POSITION_WITH_FLAGS (current_position_with_flags);
> new_position_with_flags = slot의 index가 (num_pages - 1) 과 같다면 0, 아니라면 slot을 1 증가하고 플래그를 반환합니다
> 위 방식으로 슬롯을 순회합니다

    }


  if (!ATOMIC_CAS_64 (&dwb_Global.position_with_flags, current_position_with_flags, new_position_with_flags))
> 만약 다른 스레드에서 처리가 이뤄져 플래그가 바뀌었다면, 다시 처음부터 시작합니다.
> 그게 아니라면 dwb_Global.position_with_flags에 새 플래그를 대입합니다
    {
      goto start;
    }

  block = dwb_Global.blocks + current_block_no;
> block = 포인터 dwb_Global.blocks에 현재 블록 번호를 더한 포인터

  *p_dwb_slot = block->slots + position_in_current_block;
> *p_dwb_slot = 해당 블록의 슬롯 포인터에 슬롯 위치를 더한 포인터

  /* Invalidate slot content. */
  VPID_SET_NULL (&(*p_dwb_slot)->vpid);

  assert ((*p_dwb_slot)->position_in_block == position_in_current_block);

  return NO_ERROR;
> 
}
```

<br />
<br />
<br />

### dwb_wait_for_strucure_modification

```cpp
STATIC_INLINE DWB_WAIT_QUEUE_ENTRY *
dwb_make_wait_queue_entry (DWB_WAIT_QUEUE * wait_queue, void *data)
{
  DWB_WAIT_QUEUE_ENTRY *wait_queue_entry;

  assert (wait_queue != NULL && data != NULL);

  if (wait_queue->free_list != NULL)
    {
      wait_queue_entry = wait_queue->free_list;
      wait_queue->free_list = wait_queue->free_list->next;
      wait_queue->free_count--;
    }
> freelist 가 존재한다면 freelist에서 가져와서 사용
  else
    {
      wait_queue_entry = (DWB_WAIT_QUEUE_ENTRY *) malloc (sizeof (DWB_WAIT_QUEUE_ENTRY));
> 없다면 직접 할당

      if (wait_queue_entry == NULL)
	{
	  er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_OUT_OF_VIRTUAL_MEMORY, 1, sizeof (DWB_WAIT_QUEUE_ENTRY));
	  return NULL;
	}
> 에러처리
    }

  wait_queue_entry->data = data;
> data는 스레드 포인터
  wait_queue_entry->next = NULL;
  return wait_queue_entry;
> 블록 초기화 및 반환
}


STATIC_INLINE DWB_WAIT_QUEUE_ENTRY *
dwb_block_add_wait_queue_entry (DWB_WAIT_QUEUE * wait_queue, void *data)
{
  DWB_WAIT_QUEUE_ENTRY *wait_queue_entry = NULL;

  assert (wait_queue != NULL && data != NULL);

  wait_queue_entry = dwb_make_wait_queue_entry (wait_queue, data);
> wait queue에 들어갈 대기열 생성

  if (wait_queue_entry == NULL)
    {
      return NULL;
> 할당 오류
    }

  if (wait_queue->head == NULL)
    {
      wait_queue->tail = wait_queue->head = wait_queue_entry;
> wait_queue가 비어있으면 head = tail = wait_queue_entry
    }
  else
    {
      wait_queue->tail->next = wait_queue_entry;
      wait_queue->tail = wait_queue_entry;
> tail->next에 해당 블록을 넣고 tail을 마지막 블록으로 정리
    }
  wait_queue->count++;
> count + 1

  return wait_queue_entry;
}



STATIC_INLINE int
dwb_wait_for_strucure_modification (THREAD_ENTRY * thread_p)
{
#if defined (SERVER_MODE)
  int error_code = NO_ERROR;
  DWB_WAIT_QUEUE_ENTRY *double_write_queue_entry = NULL;
  UINT64 current_position_with_flags;
  int r;
  struct timeval timeval_crt, timeval_timeout;
  struct timespec to;
  bool save_check_interrupt;

  (void) pthread_mutex_lock (&dwb_Global.mutex);
> wait queue의 수정에 앞서 lock

  current_position_with_flags = ATOMIC_INC_64 (&dwb_Global.position_with_flags, 0ULL);
> current_position_with_flags = dwb_Global.position_with_flags

  if (!DWB_IS_MODIFYING_STRUCTURE (current_position_with_flags))
> 불필요한 대기를 피하기 위해 DWB 가 생성중이 아니라면
    {
      pthread_mutex_unlock (&dwb_Global.mutex);
      return NO_ERROR;
> lock을 해제하고 종료
    }

  thread_lock_entry (thread_p);
> 해당 스레드도 lock

  double_write_queue_entry = dwb_block_add_wait_queue_entry (&dwb_Global.wait_queue, thread_p);
> wait queue에 대기열 추가
  if (double_write_queue_entry == NULL)
    {
      /* allocation error */
      thread_unlock_entry (thread_p);
      pthread_mutex_unlock (&dwb_Global.mutex);

      ASSERT_ERROR_AND_SET (error_code);
      return error_code;
> 실패했으면 에러처리
    }

  pthread_mutex_unlock (&dwb_Global.mutex);
> 스레드 unlock

  save_check_interrupt = logtb_set_check_interrupt (thread_p, false);

  gettimeofday (&timeval_crt, NULL);
  timeval_add_msec (&timeval_timeout, &timeval_crt, 10);
  timeval_to_timespec (&to, &timeval_timeout);
> timeout을 위한 설정

  r = thread_suspend_timeout_wakeup_and_unlock_entry (thread_p, &to, THREAD_DWB_QUEUE_SUSPENDED);
> 실질적 대기, 내부에서 pthread_cond_timedwait 함수를 호출하여 대기가 일어남
> pthread_cond_timedwait는 리눅스 함수이므로, 윈도우의 경우에는 동일 이름으로 함수를 구현하여 제공

  (void) logtb_set_check_interrupt (thread_p, save_check_interrupt);
  if (r == ER_CSS_PTHREAD_COND_TIMEDOUT)
    {
      /* timeout, remove the entry from queue */
      dwb_remove_wait_queue_entry (&dwb_Global.wait_queue, &dwb_Global.mutex, thread_p, NULL);
      return r;
> timeout 처리

    }
  else if (thread_p->resume_status != THREAD_DWB_QUEUE_RESUMED)
    {
      assert (thread_p->resume_status == THREAD_RESUME_DUE_TO_SHUTDOWN);

      dwb_remove_wait_queue_entry (&dwb_Global.wait_queue, &dwb_Global.mutex, thread_p, NULL);
      er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_INTERRUPTED, 0);
      return ER_INTERRUPTED;
> 인터럽트가 일어났을 경우 처리

    }
  else
    {
      assert (thread_p->resume_status == THREAD_DWB_QUEUE_RESUMED);
      return NO_ERROR;
> 종료

    }
#else /* !SERVER_MODE */
  return NO_ERROR;
#endif /* !SERVER_MODE */
}
```

<br />
<br />
<br />


### dwb_set_slot_data

```cpp
slot이 가리키는 위치에 데이터를 놓습니다

return         : 에러 코드
dwb_slot       : slot 위치가 되는 포인터
io_page_p      : 데이터 페이지
```

```cpp
STATIC_INLINE void
dwb_set_slot_data (THREAD_ENTRY * thread_p, DWB_SLOT * dwb_slot, FILEIO_PAGE * io_page_p)
{
  assert (dwb_slot != NULL && io_page_p != NULL);

  assert (io_page_p->prv.p_reserve_2 == 0);

  if (io_page_p->prv.pageid != NULL_PAGEID)
> 데이터 페이지의 페이지가 유효하다면 
    {
      memcpy (dwb_slot->io_page, (char *) io_page_p, IO_PAGESIZE);
> 슬롯의 페이지 위치에 해당 페이지 복사
    }
  else
    {
      /* Initialize page for consistency. */
      fileio_initialize_res (thread_p, dwb_slot->io_page, IO_PAGESIZE);
> 슬롯의 페이지 자체를 초기화
    }

  assert (fileio_is_page_sane (io_page_p, IO_PAGESIZE));
  LSA_COPY (&dwb_slot->lsa, &io_page_p->prv.lsa);
  VPID_SET (&dwb_slot->vpid, io_page_p->prv.volid, io_page_p->prv.pageid);
> dwb_slot->vpid.volid = io_page_p->prv.volid
> dwb_slot->vpid.pageid = io_page_p->prv.pageid
}
```
