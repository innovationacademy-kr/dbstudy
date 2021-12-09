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

```
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
  position_in_current_block = DWB_GET_POSITION_IN_BLOCK (current_position_with_flags);

  assert (current_block_no < DWB_NUM_TOTAL_BLOCKS && position_in_current_block < DWB_BLOCK_NUM_PAGES);

  if (position_in_current_block == 0)
    {
      /* This is the first write on current block. Before writing, check whether the previous iteration finished. */
      if (DWB_IS_BLOCK_WRITE_STARTED (current_position_with_flags, current_block_no))
	{
	  if (can_wait == false)
	    {
	      return NO_ERROR;
	    }

	  dwb_log ("Waits for flushing block=%d having version=%lld) \n",
		   current_block_no, dwb_Global.blocks[current_block_no].version);

	  /*
	   * The previous iteration didn't finished, needs to wait, in order to avoid buffer overwriting.
	   * Should happens relative rarely, except the case when the buffer consist in only one block.
	   */
	  error_code = dwb_wait_for_block_completion (thread_p, current_block_no);
	  if (error_code != NO_ERROR)
	    {
	      if (error_code == ER_CSS_PTHREAD_COND_TIMEDOUT)
		{
		  /* timeout, try again */
		  goto start;
		}

	      dwb_log_error ("Error %d while waiting for flushing block=%d having version %lld \n",
			     error_code, current_block_no, dwb_Global.blocks[current_block_no].version);
	      return error_code;
	    }

	  /* Probably someone else advanced the position, try again. */
	  goto start;
	}

      /* First write in the current block. */
      assert (!DWB_IS_BLOCK_WRITE_STARTED (current_position_with_flags, current_block_no));

      current_position_with_block_write_started =
	DWB_STARTS_BLOCK_WRITING (current_position_with_flags, current_block_no);

      new_position_with_flags = DWB_GET_NEXT_POSITION_WITH_FLAGS (current_position_with_block_write_started);
    }
  else
    {
      /* I'm sure that nobody else can delete the buffer */
      assert (DWB_IS_CREATED (dwb_Global.position_with_flags));
      assert (!DWB_IS_MODIFYING_STRUCTURE (dwb_Global.position_with_flags));

      /* Compute the next position with flags */
      new_position_with_flags = DWB_GET_NEXT_POSITION_WITH_FLAGS (current_position_with_flags);
    }

  /* Compute and advance the global position in double write buffer. */
  if (!ATOMIC_CAS_64 (&dwb_Global.position_with_flags, current_position_with_flags, new_position_with_flags))
    {
      /* Someone else advanced the global position in double write buffer, try again. */
      goto start;
    }

  block = dwb_Global.blocks + current_block_no;

  *p_dwb_slot = block->slots + position_in_current_block;

  /* Invalidate slot content. */
  VPID_SET_NULL (&(*p_dwb_slot)->vpid);

  assert ((*p_dwb_slot)->position_in_block == position_in_current_block);

  return NO_ERROR;
}
```
