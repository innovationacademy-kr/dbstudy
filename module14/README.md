# **DWB Flush**

## **dwb_flush_block()**

```c
/*
 * dwb_flush_block () - Flush pages from specified block.
 *
 * return   : Error code.
 * thread_p (in): Thread entry.
 * block(in): The block that needs flush.
 * file_sync_helper_can_flush(in): True, if file sync helper thread can flush.
 * current_position_with_flags(out): Current position with flags.
 *
 *  Note: The block pages can't be modified by others during flush.
 */
STATIC_INLINE int
dwb_flush_block(THREAD_ENTRY *thread_p, DWB_BLOCK *block, bool file_sync_helper_can_flush,
				UINT64 *current_position_with_flags)
{
	UINT64 local_current_position_with_flags, new_position_with_flags;
	int error_code = NO_ERROR;
	DWB_SLOT *p_dwb_ordered_slots = NULL;
	unsigned int i, ordered_slots_length;
	PERF_UTIME_TRACKER time_track;
	int num_pages;
	unsigned int current_block_to_flush, next_block_to_flush;
	int max_pages_to_sync;
#if defined(SERVER_MODE)
	bool flush = false;
	PERF_UTIME_TRACKER time_track_file_sync_helper;
#endif
#if !defined(NDEBUG)
	DWB_BLOCK *saved_file_sync_helper_block = NULL;
	LOG_LSA nxio_lsa;
#endif

	assert(block != NULL && block->count_wb_pages > 0 && dwb_is_created());

	PERF_UTIME_TRACKER_START(thread_p, &time_track);

	/* Currently we allow only one block to be flushed. */
	ATOMIC_INC_32(&dwb_Global.blocks_flush_counter, 1);
	assert(dwb_Global.blocks_flush_counter <= 1);

	/* Order slots by VPID, to flush faster. */
	error_code = dwb_block_create_ordered_slots(block, &p_dwb_ordered_slots, &ordered_slots_length);
	if (error_code != NO_ERROR)
	{
		error_code = ER_FAILED;
		goto end;
	}

	/* Remove duplicates */
	for (i = 0; i < block->count_wb_pages - 1; i++)
	{
		DWB_SLOT *s1, *s2;

		s1 = &p_dwb_ordered_slots[i];
		s2 = &p_dwb_ordered_slots[i + 1];

		assert(s1->io_page->prv.p_reserve_2 == 0);

		if (!VPID_ISNULL(&s1->vpid) && VPID_EQ(&s1->vpid, &s2->vpid))
		{
			/* Next slot contains the same page, but that page is newer than the current one. Invalidate the VPID to
	   * avoid flushing the page twice. I'm sure that the current slot is not in hash.
	   */
			assert(LSA_LE(&s1->lsa, &s2->lsa));

			VPID_SET_NULL(&s1->vpid);

			assert(s1->position_in_block < DWB_BLOCK_NUM_PAGES);
			VPID_SET_NULL(&(block->slots[s1->position_in_block].vpid));

			fileio_initialize_res(thread_p, s1->io_page, IO_PAGESIZE);
		}

		/* Check for WAL protocol. */
#if !defined(NDEBUG)
		if (s1->io_page->prv.pageid != NULL_PAGEID && logpb_need_wal(&s1->io_page->prv.lsa))
		{
			/* Need WAL. Check whether log buffer pool was destroyed. */
			nxio_lsa = log_Gl.append.get_nxio_lsa();
			assert(LSA_ISNULL(&nxio_lsa));
		}
#endif
	}

	PERF_UTIME_TRACKER_TIME(thread_p, &time_track, PSTAT_DWB_FLUSH_BLOCK_SORT_TIME_COUNTERS);

#if !defined(NDEBUG)
	saved_file_sync_helper_block = (DWB_BLOCK *)dwb_Global.file_sync_helper_block;
#endif

#if defined(SERVER_MODE)
	PERF_UTIME_TRACKER_START(thread_p, &time_track_file_sync_helper);

	while (dwb_Global.file_sync_helper_block != NULL)
	{
		flush = true;

		/* Be sure that the previous block was written on disk, before writing the current block. */
		if (dwb_is_file_sync_helper_daemon_available())
		{
			/* Wait for file sync helper. */
			thread_sleep(1);
		}
		else
		{
			/* Helper not available, flush the volumes from previous block. */
			for (i = 0; i < dwb_Global.file_sync_helper_block->count_flush_volumes_info; i++)
			{
				assert(dwb_Global.file_sync_helper_block->flush_volumes_info[i].vdes != NULL_VOLDES);

				if (ATOMIC_INC_32(&(dwb_Global.file_sync_helper_block->flush_volumes_info[i].num_pages), 0) >= 0)
				{
					(void)fileio_synchronize(thread_p,
											 dwb_Global.file_sync_helper_block->flush_volumes_info[i].vdes, NULL,
											 FILEIO_SYNC_ONLY);

					dwb_log("dwb_flush_block: Synchronized volume %d\n",
							dwb_Global.file_sync_helper_block->flush_volumes_info[i].vdes);
				}
			}
			(void)ATOMIC_TAS_ADDR(&dwb_Global.file_sync_helper_block, (DWB_BLOCK *)NULL);
		}
	}

#if !defined(NDEBUG)
	if (saved_file_sync_helper_block)
	{
		for (i = 0; i < saved_file_sync_helper_block->count_flush_volumes_info; i++)
		{
			assert(saved_file_sync_helper_block->flush_volumes_info[i].all_pages_written == true && saved_file_sync_helper_block->flush_volumes_info[i].num_pages == 0);
		}
	}
#endif

	if (flush == true)
	{
		PERF_UTIME_TRACKER_TIME(thread_p, &time_track_file_sync_helper, PSTAT_DWB_WAIT_FILE_SYNC_HELPER_TIME_COUNTERS);
	}
#endif /* SERVER_MODE */

	ATOMIC_TAS_32(&block->count_flush_volumes_info, 0);
	block->all_pages_written = false;

	/* First, write and flush the double write file buffer. */
	if (fileio_write_pages(thread_p, dwb_Global.vdes, block->write_buffer, 0, block->count_wb_pages,
						   IO_PAGESIZE, FILEIO_WRITE_NO_COMPENSATE_WRITE) == NULL)
	{
		/* Something wrong happened. */
		assert(false);
		error_code = ER_FAILED;
		goto end;
	}

	/* Increment statistics after writing in double write volume. */
	perfmon_add_stat(thread_p, PSTAT_PB_NUM_IOWRITES, block->count_wb_pages);

	if (fileio_synchronize(thread_p, dwb_Global.vdes, dwb_Volume_name, FILEIO_SYNC_ONLY) != dwb_Global.vdes)
	{
		assert(false);
		/* Something wrong happened. */
		error_code = ER_FAILED;
		goto end;
	}
	dwb_log("dwb_flush_block: DWB synchronized\n");

	/* Now, write and flush the original location. */
	error_code =
		dwb_write_block(thread_p, block, p_dwb_ordered_slots, ordered_slots_length, file_sync_helper_can_flush, true);
	if (error_code != NO_ERROR)
	{
		assert(false);
		goto end;
	}

	max_pages_to_sync = prm_get_integer_value(PRM_ID_PB_SYNC_ON_NFLUSH) / 2;

	/* Now, flush only the volumes having pages in current block. */
	for (i = 0; i < block->count_flush_volumes_info; i++)
	{
		assert(block->flush_volumes_info[i].vdes != NULL_VOLDES);

		num_pages = ATOMIC_INC_32(&block->flush_volumes_info[i].num_pages, 0);
		if (num_pages == 0)
		{
			/* Flushed by helper. */
			continue;
		}

#if defined(SERVER_MODE)
		if (file_sync_helper_can_flush == true)
		{
			if ((num_pages > max_pages_to_sync) && dwb_is_file_sync_helper_daemon_available())
			{
				/* Let the helper thread to flush volumes having many pages. */
				assert(dwb_Global.file_sync_helper_block != NULL);
				continue;
			}
		}
		else
		{
			assert(dwb_Global.file_sync_helper_block == NULL);
		}
#endif

		if (!ATOMIC_CAS_32(&block->flush_volumes_info[i].flushed_status, VOLUME_NOT_FLUSHED,
						   VOLUME_FLUSHED_BY_DWB_FLUSH_THREAD))
		{
			/* Flushed by helper. */
			continue;
		}

		num_pages = ATOMIC_TAS_32(&block->flush_volumes_info[i].num_pages, 0);
		assert(num_pages != 0);

		(void)fileio_synchronize(thread_p, block->flush_volumes_info[i].vdes, NULL, FILEIO_SYNC_ONLY);

		dwb_log("dwb_flush_block: Synchronized volume %d\n", block->flush_volumes_info[i].vdes);
	}

	/* Allow to file sync helper thread to finish. */
	block->all_pages_written = true;

	if (perfmon_is_perf_tracking_and_active(PERFMON_ACTIVATION_FLAG_FLUSHED_BLOCK_VOLUMES))
	{
		perfmon_db_flushed_block_volumes(thread_p, block->count_flush_volumes_info);
	}

	/* The block is full or there is only one thread that access DWB. */
	assert(block->count_wb_pages == DWB_BLOCK_NUM_PAGES || DWB_IS_MODIFYING_STRUCTURE(ATOMIC_INC_64(&dwb_Global.position_with_flags, 0LL)));

	ATOMIC_TAS_32(&block->count_wb_pages, 0);
	ATOMIC_INC_64(&block->version, 1ULL);

	/* Reset block bit, since the block was flushed. */
reset_bit_position:
	local_current_position_with_flags = ATOMIC_INC_64(&dwb_Global.position_with_flags, 0LL);
	new_position_with_flags = DWB_ENDS_BLOCK_WRITING(local_current_position_with_flags, block->block_no);

	if (!ATOMIC_CAS_64(&dwb_Global.position_with_flags, local_current_position_with_flags, new_position_with_flags))
	{
		/* The position was changed by others, try again. */
		goto reset_bit_position;
	}

	/* Advance flushing to next block. */
	current_block_to_flush = dwb_Global.next_block_to_flush;
	next_block_to_flush = DWB_GET_NEXT_BLOCK_NO(current_block_to_flush);

	if (!ATOMIC_CAS_32(&dwb_Global.next_block_to_flush, current_block_to_flush, next_block_to_flush))
	{
		/* I'm the only thread that can advance next block to flush. */
		assert_release(false);
	}

	/* Release locked threads, if any. */
	dwb_signal_block_completion(thread_p, block);
	if (current_position_with_flags)
	{
		*current_position_with_flags = new_position_with_flags;
	}

end:
	ATOMIC_INC_32(&dwb_Global.blocks_flush_counter, -1);

	if (p_dwb_ordered_slots != NULL)
	{
		free_and_init(p_dwb_ordered_slots);
	}

	PERF_UTIME_TRACKER_TIME(thread_p, &time_track, PSTAT_DWB_FLUSH_BLOCK_TIME_COUNTERS);

	return error_code;
}
```