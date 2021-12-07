## **`dwb_add_page`**

```c
/*
 * dwb_add_page () - Add page content to DWB.
 *
 * return   : Error code.
 * thread_p (in): The thread entry.
 * io_page_p(in): In-memory address where the current content of page resides.
 * vpid(in): Page identifier.
 * p_dwb_slot(in/out): DWB slot where the page content must be added.
 *
 *  Note: thread may flush the block, if flush thread is not available or we are in stand alone.
 */
int dwb_add_page(THREAD_ENTRY *thread_p, FILEIO_PAGE *io_page_p, VPID *vpid, DWB_SLOT **p_dwb_slot)
{
	unsigned int count_wb_pages;
	int error_code = NO_ERROR;
	bool inserted = false;
	DWB_BLOCK *block = NULL;
	DWB_SLOT *dwb_slot = NULL;
	bool needs_flush;

	assert(p_dwb_slot != NULL && (io_page_p != NULL || (*p_dwb_slot)->io_page != NULL) && vpid != NULL);

	if (thread_p == NULL)
	{
		thread_p = thread_get_thread_entry_info();
	}

	if (*p_dwb_slot == NULL)
	{
		error_code = dwb_set_data_on_next_slot(thread_p, io_page_p, true, p_dwb_slot);
		if (error_code != NO_ERROR)
		{
			return error_code;
		}

		if (*p_dwb_slot == NULL)
		{
			return NO_ERROR;
		}
	}

	dwb_slot = *p_dwb_slot;

	assert(VPID_EQ(vpid, &dwb_slot->vpid));
	if (!VPID_ISNULL(vpid))
	{
		error_code = dwb_slots_hash_insert(thread_p, vpid, dwb_slot, &inserted);
		if (error_code != NO_ERROR)
		{
			return error_code;
		}

		if (!inserted)
		{
			/* Invalidate the slot to avoid flushing the same data twice. */
			VPID_SET_NULL(&dwb_slot->vpid);
			fileio_initialize_res(thread_p, dwb_slot->io_page, IO_PAGESIZE);
		}
	}

	dwb_log("dwb_add_page: added page = (%d,%d) on block (%d) position (%d)\n", vpid->volid, vpid->pageid,
			dwb_slot->block_no, dwb_slot->position_in_block);

	block = &dwb_Global.blocks[dwb_slot->block_no];
	count_wb_pages = ATOMIC_INC_32(&block->count_wb_pages, 1);
	assert_release(count_wb_pages <= DWB_BLOCK_NUM_PAGES);

	if (count_wb_pages < DWB_BLOCK_NUM_PAGES)
	{
		needs_flush = false;
	}
	else
	{
		needs_flush = true;
	}

	if (needs_flush == false)
	{
		return NO_ERROR;
	}

	/*
   * The blocks must be flushed in the order they are filled to have consistent data. The flush block thread knows
   * how to flush the blocks in the order they are filled. So, we don't care anymore about the flushing order here.
   * Initially, we waited here if the previous block was not flushed. That approach created delays.
   */

#if defined(SERVER_MODE)
	/*
   * Wake ups flush block thread to flush the current block. The current block will be flushed after flushing the
   * previous block.
   */
	if (dwb_is_flush_block_daemon_available())
	{
		/* Wakeup the thread that will flush the block. */
		dwb_flush_block_daemon->wakeup();

		return NO_ERROR;
	}
#endif /* SERVER_MODE */

	/* Flush all pages from current block */
	error_code = dwb_flush_block(thread_p, block, false, NULL);
	if (error_code != NO_ERROR)
	{
		dwb_log_error("Can't flush block = %d having version %lld\n", block->block_no, block->version);

		return error_code;
	}

	dwb_log("Successfully flushed DWB block = %d having version %lld\n", block->block_no, block->version);

	return NO_ERROR;
}
```

## **`thread_get_thread_entry_info`**

```c
inline cubthread::entry *
thread_get_thread_entry_info (void)
{
  cubthread::entry &te = cubthread::get_entry ();
  return &te;
}
```
