# **Recovery by DWB**

## **1. 분석 문서**

### **Corrupted Data Page Recovery**

* 위에서 `Page Corrupted하다` 라는 뜻은 DB의 논리적인 Page를 write 할 때 Partial Write가 일어난 Page를 뜻한다. `Partial Write`란 논리적 Page를 디스크 Page로 저장하는 과정에서 일부를 저장하지 못하는 경우를 말한다. 또한 log를 통해 이뤄지는 recovery는 데이터 자체의 recovery이므로 DWB를 통해 이뤄지는 recovery와는 관련 없는 내용을 밝힌다. 정확히는 log recovery를 진행하기 전에 실행한다. Recovery가 시작되면, corruption test를 진행하여서 recovery를 진행할 Page를 선별하고 recovery가 불가능한 경우에는 recovery를 그대로 종료한다.

* Recovery가 시작할 때 recovery block이 만들어지며 DWB volume에 저장된 내용을 메모리에 할당시킨다. 할당된 Block은 slot ordering 을 통해서 정렬시킨 뒤, 같은 Page의 최신 Page LSA(Log Sequence Address)를 가진 Page만 Recovery에 사용된다.

* `dwb_check_data_page_is_sane()` 함수를 통해 corruption test를 진행하고, `dwb_load_and_recover_pages()` 함수를 통해 전체적인 recovery를 진행한다.

### **Corruption Test**

* 같은 volume fd, page id를 가진 recovery block의 Page와, DB의 Page의 corruption test를 각각 진행한다.

* LSA(Log Sequence Address)를 통해서 Partial Write이 일어났는지 확인한다.

* Recovery block에서 corruption이 발생했다면, recovery를 잘못된 data로 진행하는 것이 되기 때문에 recovery를 중지한다.

* Recovery block에서 corruption이 발생하지 않았다면, 해당 page는 recovery에 사용 가능하다.

* DB Page가 corruption이 발생했다면, 그 다음 Page의 corruption test를 진행한다.

* DB Page가 corruption이 발생하지 않았다면, 해당 slot은 NULL로 초기화 시켜서 recovery 속도를 향상시킬 수 있게 한다.

### **Recovery**

* 정렬된 Recovery block을 DB에 Flush를 진행한다.

* DWB block을 DB에 write하는 방식처럼 slot을 정렬한 뒤 write을 진행한다. Write을 진행한 다음 곧바로 Page에 대해서 Flush를 진행한다.

![](https://images.velog.io/images/dogfootbirdfoot/post/6aca14ec-3be5-45b4-92df-26ca01ff9aec/%E1%84%89%E1%85%B3%E1%84%8F%E1%85%B3%E1%84%85%E1%85%B5%E1%86%AB%E1%84%89%E1%85%A3%E1%86%BA%202022-01-03%20%E1%84%8B%E1%85%A9%E1%84%92%E1%85%AE%204.11.40.png)

## **2. 코드 분석**

### **dwb_load_and_recover_pages()**

*storage/double_write_buffer.c: 3094*

```cpp
/*
 * dwb_load_and_recover_pages () : DWB에서 페이지를 로드하고 복구
 *
 * return   : Error code.
 * thread_p (in): The thread entry.
 * dwb_path_p (in): The double write buffer path.
 * db_name_p (in): The database name.
 *
 * Note:	이 함수는 recovery 시 호출된다.
 *			Corrupted pages는 double write buffer disk에서 복구된다.
 * 			그런 다음 사용자가 명시하는대로 double write buffer가 재생성된다.
 *			현재 우리는 corrupted page를 복구하기 위해 memory의 DWB block을 사용한다.
 */
int dwb_load_and_recover_pages(THREAD_ENTRY *thread_p, const char *dwb_path_p, const char *db_name_p)
{
	int error_code = NO_ERROR, read_fd = NULL_VOLDES;
	unsigned int num_dwb_pages, ordered_slots_length, i;
	DWB_BLOCK *rcv_block = NULL;
	DWB_SLOT *p_dwb_ordered_slots = NULL;
	FILEIO_PAGE *iopage;
	int num_recoverable_pages;

	assert(dwb_Global.vdes == NULL_VOLDES);
	// dwb_Global의 vdes가 유효한 값이라면 crash

	dwb_check_logging();
	// #define dwb_check_logging() (dwb_Log = prm_get_bool_value(PRM_ID_DWB_LOGGING))

	fileio_make_dwb_name(dwb_Volume_name, dwb_path_p, db_name_p);
	// DWB volume의 이름 지정

	if (fileio_is_volume_exist(dwb_Volume_name))
	// 인자로 넘긴 이름의 volume이 존재한다면
	{
		/* Open DWB volume first */
		read_fd = fileio_mount(thread_p, boot_db_full_name(), dwb_Volume_name, LOG_DBDWB_VOLID, false, false);
		// 해당 이름(및 식별자)의 volume을 mount(open)
		if (read_fd == NULL_VOLDES)
		// 실패 시
		{
			return ER_IO_MOUNT_FAIL;
			// #define ER_IO_MOUNT_FAIL -10
		}

		num_dwb_pages = fileio_get_number_of_volume_pages(read_fd, IO_PAGESIZE);
		// open한 DWB volume의 page 수 구하기(volume의 크기)
		dwb_log("dwb_load_and_recover_pages: The number of pages in DWB %d\n", num_dwb_pages);
		// 구한 volume의 page 수 로그 기록

		/* We are in recovery phase. The system may be restarted with DWB size different than parameter value.
		 * There may be one of the following two reasons:
		 *   - the user may intentionally modified the DWB size, before restarting.
		 *   - DWB size didn't changed, but the previous DWB was created, partially flushed and the system crashed.
		 * We know that a valid DWB size must be a power of 2.
		 * In this case we recover from DWB.
		 * Otherwise, skip recovering from DWB - the modifications are not reflected in data pages.
		 * Another approach would be to recover, even if the DWB size is not a power of 2 (DWB partially flushed).
		 *
		 * 우리는 recovery 단계에 있다. 매개변수 값과 다른 DWB 크기로 시스템이 재시작될 수도 있다.
		 * 이는 다음 두 가지 이유 중 하나일 수 있다.
		 * 		1. 사용자는 재시작 전에 의도적으로 DWB 크기를 수정할 수 있다.
		 * 		2. DWB 크기는 변경되지 않았지만, 이전 DWB가 생성되어 부분적으로 flush되고 system crash가 일어났다.
		 * DWB의 크기는 2의 거듭제곱이어야 한다.
		 * 그렇지 않으면 DWB recovery를 건너뛴다 - 변경사항이 data page에 반영되지 않는다.
		 * 또 다른 방식은 DWB의 크기가 2의 거듭제곱이 아닌 경우에도 recover하는 것이다. (DWB가 부분적으로 flush됨)
		 */
		if ((num_dwb_pages > 0) && IS_POWER_OF_2(num_dwb_pages))
		// DWB에 page가 존재하고 그 수가 2의 거듭제곱이라면
		{
			/* Create DWB block for recovery purpose. */
			error_code = dwb_create_blocks(thread_p, 1, num_dwb_pages, &rcv_block);
			// recovery 용도의 DWB 단일 블록을 생성
			if (error_code != NO_ERROR)
			{
				// 실패 시
				goto end;
			}

			/* Read pages in block write area. This means that slot pages are set. */
			// 블록 쓰기(write)영역에서 페이지들을 읽는다. 이것은 슬롯 페이지들이 set되었음을 의미한다.
			// DWB volume에서 read로 rcv_block->write_buffer에 내용을 채운다. (volume 전체)
			if (fileio_read_pages(thread_p, read_fd, rcv_block->write_buffer, 0, num_dwb_pages, IO_PAGESIZE) == NULL)
			{
				// 실패 시
				error_code = ER_FAILED;
				goto end;
			}

			/* Set slots VPID and LSA from pages. */
			// 페이지에서 슬롯 VPID 및 LSA 설정
			for (i = 0; i < num_dwb_pages; i++)
			{
				// 페이지 수만큼 반목문을 돌면서
				iopage = rcv_block->slots[i].io_page;
				// iopage 포인터 변수에 읽은 페이지를 저장하고

				VPID_SET(&rcv_block->slots[i].vpid, iopage->prv.volid, iopage->prv.pageid);
				// volid 및 pageid 값으로 VPID 설정
				LSA_COPY(&rcv_block->slots[i].lsa, &iopage->prv.lsa);
				// &rcv_block->slots[i].lsa = &iopage->prv.lsa
			}
			rcv_block->count_wb_pages = num_dwb_pages;

			/* Order slots by VPID, to flush faster. */
			error_code = dwb_block_create_ordered_slots(rcv_block, &p_dwb_ordered_slots, &ordered_slots_length);
			// 빠른 flush를 위해 블록의 슬롯들을 p_dwb_ordered_slots에 VPID 순으로 정렬
			if (error_code != NO_ERROR)
			{
				// 실패 시
				error_code = ER_FAILED;
				goto end;
			}

			/* Remove duplicates. Normally, we do not expect duplicates in DWB. 
			 * However, this happens if the system crashes in the middle of flushing into double write file.
			 * In this case, some pages in DWB are from the last DWB flush and the other from the previous DWB flush.
			 *
			 * 중복 제거하기. 일반적인 경우에는 DWB에서 중복이 일어나진 않는다.
			 * 하지만 double write file로 flush하는 도중 system crash가 일어나면 중복이 일어난다.
			 * 이 경우, DWB의 일부 페이지는 가장 최근 flush에서 가져온 것이고 다른 페이지는 이전 flush에서 가져온 것이다.
			 */
			for (i = 0; i < rcv_block->count_wb_pages - 1; i++)
			{
				// 페이지 수 - 1만큼 반복문을 돌면서
				DWB_SLOT *s1, *s2;

				s1 = &p_dwb_ordered_slots[i];
				s2 = &p_dwb_ordered_slots[i + 1];

				if (!VPID_ISNULL(&s1->vpid) && VPID_EQ(&s1->vpid, &s2->vpid))
				// s1의 VPID가 NULL이 아니고 s1과 s2의 VPID가 같으면
				{
					/* Next slot contains the same page. Search for the oldest version. */
					// 다음 슬롯에 동일한 페이지가 있다. 가장 오래된 버전을 검색한다.
					assert(LSA_LE(&s1->lsa, &s2->lsa));
					// &s1->lsa <= &s2->lsa이 false이면 crash (s1이 더 최신이면 crash)

					dwb_log("dwb_load_and_recover_pages: Found duplicates in DWB at positions = (%d,%d) %d\n",
							s1->position_in_block, s2->position_in_block);
					// 중복을 발견했다는 로그 남김

					if (LSA_LT(&s1->lsa, &s2->lsa))
					// &s1->lsa < &s2->lsa 이면 (s2가 더 최신이면)
					{
						/* Invalidate the oldest page version. */
						VPID_SET_NULL(&s1->vpid);
						// 더 오래된 페이지 버전인 s1 무효화
						dwb_log("dwb_load_and_recover_pages: Invalidated the page at position = (%d)\n",
								s1->position_in_block);
						// 무효화 시켰다는 로그 남김
					}
					else
					{
					/* Same LSA. This is the case when page was modified without setting LSA.
		    		 * The first appearance in DWB contains the oldest page modification - last flush in DWB!
					 *
					 * LSA가 같음. 이는 LSA를 설정하지 않고 페이지를 수정한 경우이다.
					 * DWB에 가장 오래된 페이지 수정이 포함되어 있다 - DWB의 마지막 flush
		    		 */
						assert(s1->position_in_block != s2->position_in_block);
						// s1의 position_in_block이 s2의 position_in_block과 같으면 crash

						if (s1->position_in_block < s2->position_in_block)
						// s2가 더 최신이면
						{
							/* Page of s1 is valid. */
							VPID_SET_NULL(&s2->vpid);
							// s1의 페이지가 유효하므로 s2의 VPID 무효화
							dwb_log("dwb_load_and_recover_pages: Invalidated the page at position = (%d)\n",
									s2->position_in_block);
						}
						else
						// s1이 더 최신이면
						{
							/* Page of s2 is valid. */
							VPID_SET_NULL(&s1->vpid);
							// s2의 페이지가 유효하므로 s1의 VPID 무효화
							dwb_log("dwb_load_and_recover_pages: Invalidated the page at position = (%d)\n",
									s1->position_in_block);
						}
					}
				}
			}

#if !defined(NDEBUG)		// DEBUG 모드로 실행됐을 경우
			// check sanity of ordered slots
			error_code = dwb_debug_check_dwb(thread_p, p_dwb_ordered_slots, num_dwb_pages);
			// 정렬된 슬롯의 온전성 확인
			if (error_code != NO_ERROR)
			{
				// 실패 시
				goto end;
			}
#endif // DEBUG

			/* Check whether the data page is corrupted. If the case, it will be replaced with the DWB page. */
			error_code = dwb_check_data_page_is_sane(thread_p, rcv_block, p_dwb_ordered_slots, &num_recoverable_pages);
			// 데이터 페이지가 corrupted되었는지 확인. 이 경우 DWB 페이지로 대체된다.
			if (error_code != NO_ERROR)
			{
				// 실패 시
				goto end;
			}

			if (0 < num_recoverable_pages)
			// recover 가능한 corrupted page가 있다면
			{
				/* Replace the corrupted pages in data volume with the DWB content. */
				error_code =
					dwb_write_block(thread_p, rcv_block, p_dwb_ordered_slots, ordered_slots_length, false, false);
				// Data volume의 corrupted pages를 DWB content로 교체
				if (error_code != NO_ERROR)
				{
					// 실패 시
					goto end;
				}

				/* Now, flush the volumes having pages in current block. */
				// 이제 현재 블록에 페이지가 있는 volumes를 flush
				for (i = 0; i < rcv_block->count_flush_volumes_info; i++)
				{
					if (fileio_synchronize(thread_p, rcv_block->flush_volumes_info[i].vdes, NULL,
										   FILEIO_SYNC_ONLY) == NULL_VOLDES)
					// Database volume의 상태를 disk의 상태와 동기화
					{
						// 실패 시
						error_code = ER_FAILED;
						goto end;
					}

					dwb_log("dwb_load_and_recover_pages: Synchronized volume %d\n",
							rcv_block->flush_volumes_info[i].vdes);
					// 동기화 했다는 로그 남김
				}

				rcv_block->count_flush_volumes_info = 0;
				// flush 완료 했으니 count 변수 0으로 초기화
			}

			assert(rcv_block->count_flush_volumes_info == 0);
			// flush가 필요한 count 변수가 0이 아니면 crash
		}

		/* Dismount the file. */
		fileio_dismount(thread_p, read_fd);
		// mount했던 file을 dismount

		/* Destroy the old file, since data recovered. */
		fileio_unformat(thread_p, dwb_Volume_name);
		// Data가 recover되었으므로 이전 file 폐기
		read_fd = NULL_VOLDES;
	}

	/* Since old file destroyed, now we can rebuild the new double write buffer with user specifications. */
	error_code = dwb_create(thread_p, dwb_path_p, db_name_p);
	// 오래된 file이 파기되었으므로 이제 사용자 지정으로 새로운 DWB를 다시 생성한다.
	if (error_code != NO_ERROR)
	{
		// 실패 시
		dwb_log_error("Can't create DWB \n");
	}

end:
	/* Do not remove the old file if an error occurs. */
	// 에러 발생 시 이전 파일을 폐기하면 안된다.
	if (p_dwb_ordered_slots != NULL)
	{
		free_and_init(p_dwb_ordered_slots);
		// #define free_and_init(ptr) do { free ((void*) (ptr)); (ptr) = NULL; } while (0)
	}

	if (rcv_block != NULL)
	{
		dwb_finalize_block(rcv_block);
		// rcv_block->slots, rcv_block->write_buffer, rcv_block->flush_volumes_info을 free_and_init()
		// dwb_destroy_wait_queue(&rcv_block->wait_queue, &rcv_block->mutex);
		// pthread_mutex_destroy(&rcv_block->mutex);
		free_and_init(rcv_block);
	}

	return error_code;
}
```
