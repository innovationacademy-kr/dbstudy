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

  /* Acquire the slot before setting the data. */
  error_code = dwb_acquire_next_slot (thread_p, can_wait, p_dwb_slot);
  if (error_code != NO_ERROR)
    {
      return error_code;
    }

  assert (can_wait == false || *p_dwb_slot != NULL);
  if (*p_dwb_slot == NULL)
    {
      /* Can't acquire next slot. */
      return NO_ERROR;
    }

  /* Set data on slot. */
  dwb_set_slot_data (thread_p, *p_dwb_slot, io_page_p);

  return NO_ERROR;
}
```
