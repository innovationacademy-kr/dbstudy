# dwb_flush_block

## Ordering slots

```cpp

DWB_SLOT *p_dwb_ordered_slots = NULL;

error_code = dwb_block_create_ordered_slots (block, &p_dwb_ordered_slots, &ordered_slots_length);
// Slot ordering은 두가지 장점때문에 진행한다.
// 1. DB에 있는 volume들이 VPID순서로 정렬된다.
// 2. 같은 Page는 Page LSA를 통해서 최신 버젼만 Flush.
for (i = 0; i < block->count_wb_pages - 1; i++)
{
	DWB_SLOT *s1, *s2;

  s1 = &p_dwb_ordered_slots[i];
  s2 = &p_dwb_ordered_slots[i + 1];
  assert (s1->io_page->prv.p_reserve_2 == 0);
  if (!VPID_ISNULL (&s1->vpid) && VPID_EQ (&s1->vpid, &s2->vpid))
	{
	  assert (LSA_LE (&s1->lsa, &s2->lsa));
	  VPID_SET_NULL (&s1->vpid);
	  assert (s1->position_in_block < DWB_BLOCK_NUM_PAGES);
	  VPID_SET_NULL (&(block->slots[s1->position_in_block].vpid));
	  fileio_initialize_res (thread_p, s1->io_page, IO_PAGESIZE);
	}
}
// 정렬한 slot(p_dwb_ordered_slots)의 n 와 n + 1의 vpid 를 비교해서 같으면
// n번째의 slot(이전 시점의 Page LSA 가진 slot) 을 초기화한다.
```

```cpp
STATIC_INLINE int
dwb_block_create_ordered_slots (DWB_BLOCK * block, DWB_SLOT ** p_dwb_ordered_slots,
				unsigned int *p_ordered_slots_length)
{
  DWB_SLOT *p_local_dwb_ordered_slots = NULL;

  assert (block != NULL && p_dwb_ordered_slots != NULL);
  // block 과 p_dwb_ordered_slots의 포인터가 제대로 전해지지 않았으면 crush
  p_local_dwb_ordered_slots = (DWB_SLOT *) malloc ((block->count_wb_pages + 1) * sizeof (DWB_SLOT));
  // write buffer에 쓰여진 page 수만큼의 slot을 할당한다.
    if (p_local_dwb_ordered_slots == NULL)
    {
      er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_OUT_OF_VIRTUAL_MEMORY, 1,
	      (block->count_wb_pages + 1) * sizeof (DWB_SLOT));
      return ER_OUT_OF_VIRTUAL_MEMORY;
    }
    // malloc error
  memcpy (p_local_dwb_ordered_slots, block->slots, block->count_wb_pages * sizeof (DWB_SLOT));
  // block의 slots을 memcpy 한다.
  dwb_init_slot (&p_local_dwb_ordered_slots[block->count_wb_pages]);
  // 마지막 slot을 초기화한다. (memcpy가 안 된 마지막 slot이다.)
  // 아마 ordered slot 의 마지막이란 것을 나타내기 위해 쓰는 것 같다?(char *의 \0 같은)
  qsort ((void *) p_local_dwb_ordered_slots, block->count_wb_pages, sizeof (DWB_SLOT), dwb_compare_slots);
  // 복사해온 block의 slot을 qsort 한다. 값이 크면 1 (뒤로 밀린다.)
  // vpid.volid 순서대로 정렬 같으면 vpid.pageid, lsa.pageid, lsa.offset 순으로 정렬
  *p_dwb_ordered_slots = p_local_dwb_ordered_slots;
  *p_ordered_slots_length = block->count_wb_pages + 1;
  return NO_ERROR;
}
```

## dwb_volume_flush

```cpp
fileio_write_pages (thread_p, dwb_Global.vdes, block->write_buffer, 0, block->count_wb_pages,
			  IO_PAGESIZE, FILEIO_WRITE_NO_COMPENSATE_WRITE)
// System crash가 일어나기 전에 DWB volume으로 먼저 Flush한다.
// 빠르게 flush 하기위해 한개의 block을 한번에 write 한다.
// write_buffer을 사용해 slot의 순서대로 write를 진행한다.
fileio_synchronize (thread_p, dwb_Global.vdes, dwb_Volume_name, FILEIO_SYNC_ONLY);
// fileio_synchronize()로 fsync()를 호출해 Flush를 마무리한다.
dwb_log ("dwb_flush_block: DWB synchronized\n");
```

```cpp
void *
fileio_write_pages (THREAD_ENTRY * thread_p, int vol_fd, char *io_pages_p, PAGEID page_id, int num_pages,
		    size_t page_size, FILEIO_WRITE_MODE write_mode)
{
#if defined (EnableThreadMonitoring)
  TSC_TICKS start_tick, end_tick;
  TSCTIMEVAL elapsed_time;
#endif
  off_t offset;
  ssize_t nbytes_written;
  size_t nbytes_to_be_written;

  assert (num_pages > 0);
  offset = FILEIO_GET_FILE_SIZE (page_size, page_id);
  // page_size * page_id page_id 가 0 이므로 offset = 0
  nbytes_to_be_written = ((size_t) page_size) * ((size_t) num_pages);
  // 써야하는 byte 수 
  while (nbytes_to_be_written > 0)
  {
    nbytes_written = fileio_os_write (thread_p, vol_fd, io_pages_p, nbytes_to_be_written, offset);
    // dwb volume 에 io_pages_p(write buffer) 를 offset 위치에서 (처음엔 0)(lseek 으로 파일 커서조정)
    // nbytes_to_be_written 만큼 write
    offset += nbytes_written;
    io_pages_p += nbytes_written;
    nbytes_to_be_written -= nbytes_written;
  } // 한번에 write가 안될수도 있으니 반복해서 시도
  return io_pages_p;
}
```

## db_volume_flush

```cpp
error_code =
    dwb_write_block (thread_p, block, p_dwb_ordered_slots, ordered_slots_length, file_sync_helper_can_flush, true);
// DB에 해당하는 Page마다 write() 함수를 호출하여 write를 진행한다.
max_pages_to_sync = prm_get_integer_value (PRM_ID_PB_SYNC_ON_NFLUSH) / 2;
for (i = 0; i < block->count_flush_volumes_info; i++)
{
  assert (block->flush_volumes_info[i].vdes != NULL_VOLDES);
  num_pages = ATOMIC_INC_32 (&block->flush_volumes_info[i].num_pages, 0);
--------------------------------------------------
  if (num_pages == 0)
    continue;
  // Flushed by helper.
  #if defined (SERVER_MODE)
    if (file_sync_helper_can_flush == true)
    {
      if ((num_pages > max_pages_to_sync) && dwb_is_file_sync_helper_daemon_available ())
      {
	assert (dwb_Global.file_sync_helper_block != NULL);
	continue;
      }
    }
    else
    {
      assert (dwb_Global.file_sync_helper_block == NULL);
    }
  #endif
  if (!ATOMIC_CAS_32 (&block->flush_volumes_info[i].flushed_status, VOLUME_NOT_FLUSHED,
			 VOLUME_FLUSHED_BY_DWB_FLUSH_THREAD))
	continue;
	// dwb_write_block()에서 flush_volumes_info 사용할때 VOLUME_NOT_FLUSHED 로 초기화
	//	Flushed by helper.
----------------------------------------------
helper가 처리중이거나 처리한 경우 continue ;
  num_pages = ATOMIC_TAS_32 (&block->flush_volumes_info[i].num_pages, 0);
  assert (num_pages != 0);
  (void) fileio_synchronize (thread_p, block->flush_volumes_info[i].vdes, NULL, FILEIO_SYNC_ONLY);
  // sync daemon을 호출 불가능 할 경우 fileio_synchronisize()로 fsync()를 직접 호출한다.
  dwb_log ("dwb_flush_block: Synchronized volume %d\n", block->flush_volumes_info[i].vdes);
}
 /* Allow to file sync helper thread to finish. */
 block->all_pages_written = true;
```

```cpp
STATIC_INLINE int
dwb_write_block (THREAD_ENTRY * thread_p, DWB_BLOCK * block, DWB_SLOT * p_dwb_ordered_slots,
		 unsigned int ordered_slots_length, bool file_sync_helper_can_flush, bool remove_from_hash)
{
  VOLID last_written_volid;
  int last_written_vol_fd, vol_fd;
  int count_writes = 0, num_pages_to_sync;
  FLUSH_VOLUME_INFO *current_flush_volume_info = NULL;
  bool can_flush_volume = false;

  assert (block != NULL && p_dwb_ordered_slots != NULL);
  assert (block->count_wb_pages < ordered_slots_length);
  assert (block->count_flush_volumes_info == 0);

  num_pages_to_sync = prm_get_integer_value (PRM_ID_PB_SYNC_ON_NFLUSH);
  // 74
  last_written_volid = NULL_VOLID;
  last_written_vol_fd = NULL_VOLDES;
  // page를 vpid 순으로 정렬했기때문에 같은 volume 일때는 vol_fd를 다시 구하지 않게
  // last_written_volid 와 last_wrtitten_vol_fd 를 들고다닌다

  for (i = 0; i < block->count_wb_pages; i++)
  {
    vpid = &p_dwb_ordered_slots[i].vpid;
    if (VPID_ISNULL (vpid))
      continue;
      // 중복 슬롯이라 제거됐으면, continue
    assert (VPID_ISNULL (&p_dwb_ordered_slots[i + 1].vpid) || VPID_LT (vpid, &p_dwb_ordered_slots[i + 1].vpid));
    // 다음 슬롯의 vpid 가 NULL 이 아니고 현재 슬롯의 vpid 보다 크거나 같지 않으면 clush (정렬이 안 됐다는 것이다)
    if (last_written_volid != vpid->volid)
    // 현재 slot 의 vpid 와 같지 않으면 새로운 volome 이니 fd를 얻어온다.
    {
    	/* Get the volume descriptor. */
       if (current_flush_volume_info != NULL)
       {
         assert_release (current_flush_volume_info->vdes == last_written_vol_fd);
	 current_flush_volume_info->all_pages_written = true;
	 can_flush_volume = true;
	 current_flush_volume_info = NULL;	/* reset */
       }
       // write가 완료된 volume의 flush_volume_info에 모든 pages 가 write 됐고
       // flush 해도 된다는 flag 를 주고 current_flush_volume_info 를 초기화 
       vol_fd = fileio_get_volume_descriptor (vpid->volid);
       // 현재 슬롯의 vpid 의 fd 를 구해온다.
       if (vol_fd == NULL_VOLDES)
       {
	  /* probably it was removed meanwhile. skip it! */
	  continue;
       }
       // 삭제된 볼륨이니 skip
       last_written_volid = vpid->volid;
       last_written_vol_fd = vol_fd;
       // 현재 volume의 volid, vol_fd로 바꿔준다.
       current_flush_volume_info = dwb_add_volume_to_block_flush_area (thread_p, block, last_written_vol_fd);
       // 현재 volume 에 flush 해야하니 새로운 flush_volume_info 받아옴
       // flush 한 볼륨의 수만큼 사용
    }
    assert (last_written_vol_fd != NULL_VOLDES);
    assert (p_dwb_ordered_slots[i].io_page->prv.p_reserve_2 == 0);
    assert (p_dwb_ordered_slots[i].vpid.pageid == p_dwb_ordered_slots[i].io_page->prv.pageid
		&& p_dwb_ordered_slots[i].vpid.volid == p_dwb_ordered_slots[i].io_page->prv.volid);
    /* Write the data. */
    if (fileio_write (thread_p, last_written_vol_fd, p_dwb_ordered_slots[i].io_page, vpid->pageid, IO_PAGESIZE,
			FILEIO_WRITE_NO_COMPENSATE_WRITE) == NULL)
    // db volume 에 slot의 page 를 offset(page_id * page_size) 위치에서 page_size만큼 write.
    // dwb volume 에 write 할때 사용한 fileio_write_pages와 차이는
    // write_pages 는 반복문으로 written 된 offset 에서 다시 write 하지만
    // write 는 page를 다 쓰지 못했을시 page를 다시 write 한다.
    {
      ASSERT_ERROR ();
      dwb_log_error ("DWB write page VPID=(%d, %d) LSA=(%lld,%d) with %d error: \n",
			vpid->volid, vpid->pageid, p_dwb_ordered_slots[i].io_page->prv.lsa.pageid,
			(int) p_dwb_ordered_slots[i].io_page->prv.lsa.offset, er_errid ());
      assert (false);
      /* Something wrong happened. */
      return ER_FAILED;
    }
    dwb_log ("dwb_write_block: written page = (%d,%d) LSA=(%lld,%d)\n",
		vpid->volid, vpid->pageid, p_dwb_ordered_slots[i].io_page->prv.lsa.pageid,
		(int) p_dwb_ordered_slots[i].io_page->prv.lsa.offset);
    #if defined (SERVER_MODE)
      assert (current_flush_volume_info != NULL);
      ATOMIC_INC_32 (&current_flush_volume_info->num_pages, 1);
      // num_pages : 해당 volume 에 write 수
      count_writes++;
      // sync daemon을 사용할 수 있을 때 현재 volume의 write 수가 num_pages_to_sync 파라미터 값(74)
      // 보다 클시 daemon을 통해 flush 하기위해 사용
      if (file_sync_helper_can_flush && (count_writes >= num_pages_to_sync || can_flush_volume == true)
		&& dwb_is_file_sync_helper_daemon_available ())
      // file_sync_helper가 flush 할 수 있고(and), count_writes 가 num_pages_to_sync
      // 보다 크거나(or) can_flush_volume 이 true이고(위에서 다른 vpid 일때, 즉 volume 이 변한경우)
      // sync daemon이 사용 가능할 경우
      {
	if (ATOMIC_CAS_ADDR (&dwb_Global.file_sync_helper_block, (DWB_BLOCK *) NULL, block))
	{
	  dwb_file_sync_helper_daemon->wakeup ();
	}
	// Write가 끝난 뒤, sync daemon을 사용할 수 있다는 전제하에,
	// 전역변수 ‘file_sync_helper_block’에 현재 Flush하려는 Block을 참조 시킨다.
	// Daemon을 호출해도 되는 이유는 이미 DWB volume에 flush가 되었기 때문에
	// 해당 Flush가 급한 작업이 아니기 때문이다.(system crash가 발생해도 recovery 가능)
	/* Add statistics. */
	perfmon_add_stat (thread_p, PSTAT_PB_NUM_IOWRITES, count_writes);
	count_writes = 0;
	can_flush_volume = false;
      }
    #endif
  } //for문 끝

  /* the last written volume */
  if (current_flush_volume_info != NULL)
  {
    current_flush_volume_info->all_pages_written = true;
  }
  // for문에서 volid 가 다를경우 if 문으로 all_pages_wriiten = true 로 바꿔줬는데
  // 마지막 volume은 처리를 못해주니 true 로
  #if !defined (NDEBUG)
    for (i = 0; i < block->count_flush_volumes_info; i++)
    {
      assert (block->flush_volumes_info[i].all_pages_written == true);
      assert (block->flush_volumes_info[i].vdes != NULL_VOLDES);
    }
  #endif
  
  #if defined (SERVER_MODE)
    if (file_sync_helper_can_flush && (dwb_Global.file_sync_helper_block == NULL)
	   && (block->count_flush_volumes_info > 0))
    {
      /* If file_sync_helper_block is NULL, it means that the file sync helper thread does not run and was not woken yet. */
      if (dwb_is_file_sync_helper_daemon_available ()
	   && ATOMIC_CAS_ADDR (&dwb_Global.file_sync_helper_block, (DWB_BLOCK *) NULL, block))
      {
	dwb_file_sync_helper_daemon->wakeup ();
      }
    }
  #endif
  // 반복문안에서 sync daemon 호출하지 못한 경우 호출한다. (volume 이 1개고 write한 page 수가 적은 경우)
  /* Add statistics. */
  perfmon_add_stat (thread_p, PSTAT_PB_NUM_IOWRITES, count_writes);
  /* Remove the corresponding entries from hash. */
  if (remove_from_hash)
  {
    PERF_UTIME_TRACKER time_track;
    PERF_UTIME_TRACKER_START (thread_p, &time_track);
    for (i = 0; i < block->count_wb_pages; i++)
    {
      vpid = &p_dwb_ordered_slots[i].vpid;
      if (VPID_ISNULL (vpid))
      {
        continue;
      }
      assert (p_dwb_ordered_slots[i].position_in_block < DWB_BLOCK_NUM_PAGES);
      error_code = dwb_slots_hash_delete (thread_p, &block->slots[p_dwb_ordered_slots[i].position_in_block]);
      if (error_code != NO_ERROR)
      {
	return error_code;
      }
    }
    PERF_UTIME_TRACKER_TIME (thread_p, &time_track, PSTAT_DWB_DECACHE_PAGES_AFTER_WRITE);
  }
  return NO_ERROR;
}
```
