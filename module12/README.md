## dwb_slots_hash_insert ()

```C
/*
 * dwb_slots_hash_insert () - Insert entry in slots hash.
 *
 * return   : Error code.
 * thread_p (in): The thread entry.
 * vpid(in): The page identifier.
 * slot(in): The DWB slot.
 * inserted (out): 1, if slot inserted in hash.
 */

STATIC_INLINE int
dwb_slots_hash_insert (THREAD_ENTRY * thread_p, VPID * vpid, DWB_SLOT * slot, bool * inserted)
{
  int error_code = NO_ERROR;
  // NO_ERROR : 0 
  DWB_SLOTS_HASH_ENTRY *slots_hash_entry = NULL;

  assert (vpid != NULL && slot != NULL && inserted != NULL);
  // vpid, slot, inserted == NULL -> crash

  *inserted = dwb_Global.slots_hashmap.find_or_insert (thread_p, *vpid, slots_hash_entry);
/*
 * lf_hash_find_or_insert () - find or insert an entry in the hash table
 vpid 를 key 값으로 dwb_global 변수의 slots_hashmap 변수에서 해쉬 함수를 사용해 value 를 가져오고 해쉬맵을 탐색한다.
해쉬맵에서 slots_hash_entry 가 있으면 가져오고 inserted 0,
없으면 thread_p의 freelist에서 받아와 해쉬맵에 추가하고 inserted 1로 설정한다.
 */
  assert (VPID_EQ (&slots_hash_entry->vpid, &slot->vpid));
  /*
  * #define VPID_EQ(vpid_ptr1,vpid_ptr2)
  * ((vpid_ptr1) == (vpid_ptr2) || ((vpid_ptr1)->pageid == (vpid_ptr2)->pageid && (vpid_ptr1)->volid == (vpid_ptr2)->volid))
  * 같은 주소를 가르키거나, 페이지 아이디가 같거나, volid가 같아야 한다.
  */
  assert (slots_hash_entry->vpid.pageid == slot->io_page->prv.pageid
	  && slots_hash_entry->vpid.volid == slot->io_page->prv.volid);
/*
* prv.page id, prv.volid ? ? 
*/
  if (!(*inserted)) // *inserted == 0 인경우, find 한 경우
    {
      assert (slots_hash_entry->slot != NULL);
	// slot == NULL -> crash
      if (LSA_LT (&slot->lsa, &slots_hash_entry->slot->lsa))
	  // log 는 순서대로 쌓인다.
	  // slot의 lsa보다, slots_hash_entry의 lsa가 최신인 경우
	  // 같은 정보가 중복으로 들어온 경우?
	{
	  dwb_log ("DWB hash find key (%d, %d), the LSA=(%lld,%d), better than (%lld,%d): \n",
		   vpid->volid, vpid->pageid, slots_hash_entry->slot->lsa.pageid,
		   slots_hash_entry->slot->lsa.offset, slot->lsa.pageid, slot->lsa.offset);
	// The older slot is better than mine - leave it in hash.
	  pthread_mutex_unlock (&slots_hash_entry->mutex); // unlock
	  return NO_ERROR; // NO_ERROR 리턴
	}
      else if (LSA_EQ (&slot->lsa, &slots_hash_entry->slot->lsa))
	{
	  /*
	   * If LSA's are equals, still replace slot in hash. We are in "flushing to disk without logging" case.
	   * The page was modified but not logged. We have to flush this version since is the latest one.
	   */
	  // LSA 가 동일하더라도 해쉬의 슬롯을 바꾼다.
	  // Page는 변경되었지만, 로그가 남지는 않았다. flush해야함.
	  if (slots_hash_entry->slot->block_no == slot->block_no)
	    {
	      /* Invalidate the old slot, if is in the same block. We want to avoid duplicates in block at flush. */
	      assert (slots_hash_entry->slot->position_in_block < slot->position_in_block);
		  // slot->position_in_block이 더 최신임을 assert
	      VPID_SET_NULL (&slots_hash_entry->slot->vpid);
		  // hash 테이블에 있는 page id 를 null 로 바꿔줌
	      fileio_initialize_res (thread_p, slots_hash_entry->slot->io_page, IO_PAGESIZE);
			// 초기화
	      dwb_log ("Found same page with same LSA in same block - %d - at positions (%d, %d) \n",
		       slots_hash_entry->slot->position_in_block, slot->position_in_block);
			// 로그 남겨줌
	    }
	  else // LSA 가 동일한데, block_no가 다를 때
	    {
#if !defined (NDEBUG) // No Debug?
	      int old_block_no = ATOMIC_INC_32 (&slots_hash_entry->slot->block_no, 0);
		  // slot_hash_enty의 block_no 반환
	      if (old_block_no > 0)
		{
		  /* Be sure that the block containing old page version is flushed first. */
		  DWB_BLOCK *old_block = &dwb_Global.blocks[old_block_no];
		  DWB_BLOCK *new_block = &dwb_Global.blocks[slot->block_no];

		  /* Maybe we will check that the slot is still in old block. */
		  assert ((old_block->version < new_block->version)
			  || (old_block->version == new_block->version && old_block->block_no < new_block->block_no));
			  // new_block 이 더 최신임을 assert한다.

		  dwb_log ("Found same page with same LSA in 2 different blocks old = (%d, %d), new = (%d,%d) \n",
			   old_block_no, slots_hash_entry->slot->position_in_block, new_block->block_no,
			   slot->position_in_block);
		}
#endif
	    }
	}

      dwb_log ("Replace hash key (%d, %d), the new LSA=(%lld,%d), the old LSA = (%lld,%d)",
	       vpid->volid, vpid->pageid, slot->lsa.pageid, slot->lsa.offset,
	       slots_hash_entry->slot->lsa.pageid, slots_hash_entry->slot->lsa.offset);
		   // 바꿀게라고 로그 표시
    }
  else // inserted가 됐을때
    {
      dwb_log ("Inserted hash key (%d, %d), LSA=(%lld,%d)", vpid->volid, vpid->pageid, slot->lsa.pageid,
	       slot->lsa.offset);
    }

  slots_hash_entry->slot = slot; // 바꿔줌
  pthread_mutex_unlock (&slots_hash_entry->mutex); // unlock
  *inserted = true;

  return NO_ERROR;
}
```

### DWB_SLOTS_HASH_ENTRY

```C
/* Slots hash entry. */
typedef struct dwb_slots_hash_entry DWB_SLOTS_HASH_ENTRY;
struct dwb_slots_hash_entry
{
  VPID vpid;			/* Page VPID. */

  DWB_SLOTS_HASH_ENTRY *stack;	/* Used in freelist. */
  DWB_SLOTS_HASH_ENTRY *next;	/* Used in hash table. */
  pthread_mutex_t mutex;	/* The mutex. */
  UINT64 del_id;		/* Delete transaction ID (for lock free). */

  DWB_SLOT *slot;		/* DWB slot containing a page. */

  // *INDENT-OFF*
  dwb_slots_hash_entry ()
  {
    pthread_mutex_init (&mutex, NULL);
  }
  ~dwb_slots_hash_entry ()
  {
    pthread_mutex_destroy (&mutex);
  }
  // *INDENT-ON*
};
```
### LSA_LT
``` C
bool
LSA_LT (const log_lsa *plsa1, const log_lsa *plsa2)
{
  assert (plsa1 != NULL && plsa2 != NULL);
  return *plsa1 < *plsa2;
}
```

### LSA_EQ
```C
bool
LSA_EQ (const log_lsa *plsa1, const log_lsa *plsa2)
{
  assert (plsa1 != NULL && plsa2 != NULL);
  return *plsa1 == *plsa2;
}
```
