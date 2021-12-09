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

### position_with_flags

![제목 없음-2](https://user-images.githubusercontent.com/12230655/145351207-081b679b-6284-48e4-b88a-b574a628ba53.png)

<br />
<br />

## dwb_set_data_on_next_slot

### 진입점
