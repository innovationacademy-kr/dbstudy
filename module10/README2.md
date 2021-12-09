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

## dwb_set_data_on_next_slot

### 진입점

