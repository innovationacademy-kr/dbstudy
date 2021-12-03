- disk_format*() - format new volume*

```cpp
static int
disk_format(thread, dbname, volume_id, extension_info) {
	선언부: extension_info를 지역 변수에 옮김.

	if (strlen(볼륨 OS파일의 경로) > 최대 경로 길이(1024) ) {
		return error();
	}
	if (디스크 볼륨 헤더의 길이(가변) + strlen(볼륨 OS파일의 경로) > 한 페이지의 크기) {
		return error();
	}

	if (볼륨 타입 != 영구 목적 && 볼륨 타입 != 임시 목적) {
		return error();	
	}

	assert (임시 목적이고 영구 타입의 볼륨이라면 섹터 수가 최대에 도달해야만 포맷할 수 있다);
	
	if (영구 목적이라면) {
		log += undo_data // log_append_undo_data(): 반영되지 않은 연산들을 로그에 추가함.
	}

	logpb_flush_pages_direct(): flush all pages by itself.

	vdes = fileio_format(): OSfile 생성하고 volume descriptor 반환 & 메모리에 페이지 생성

	vpid.volid = volid;
        vpid.pageid = DISK_VOLHEADER_PAGE; // 0
	: 볼륨 헤더, 섹터, 페이지를 초기화

	pgptr = pgbuf_fix(vpid, ...): volume id와 page id로 버퍼상의 page pointer로 변환
	: volume의 가장 첫번째에 해당하는 포인터 반환
	
	pgbuf_set_page_ptype(): 페이지의 타입 설정. 디버깅용 설정

	vhdr = (DISK_VOLUME_HEADER *)pgptr; // volume header

	...
	extension_info등을 이용해 vhdr 초기화

	disk_volume_header_set_stab(vhdr, ...): 볼륨 헤더에 섹터 테이블의 주소 설정

        log_get_db_start_parameters(): DB의 생성 시간과 최근의 체크포인트를 찾아서 로그를 남긴다.

	vhdr->boot_hfid = NULL // 부팅을 목적으로 시스템 힙파일 초기화한다. heap file이 부트 매니저에 의해서 생성된 후 초기화 됨.

	variable length field를 초기화
  
        vhdr->next_volid = NULL_VOLID; // 다음 볼륨의 id
  
        vhdr->offset_to_vol_fullname = 0 // path를 포함한 볼륨의 전체 이름
  
	vhdr->offset_to_next_vol_fullname = 0 // 다음 볼륨의 전체 이름
  
	vhdr->offset_to_vol_remarks = 0; // 볼륨의 주석
  
        vhdr->var_fields[vhdr->offset_to_vol_fullname] = '\0'; // vol_fulname 뒤에 널문자 넣어주기

	disk_vhdr_set_vol_fullname(vhdr, vol_fullname) // vhdr에 vol_fullname을 넣는다.
  
	disk_vhdr_set_next_vol_fullname(vhdr, NULL); //  다음 볼륨이름을 정해준다.
  
	disk_vhdr_set_vol_remarks(vhdr, ext_info->comments) // 주석을 단다.
	memcpy, memmove, strncpy, strcpy 등을 통해서 var_fields는 세 부분으로 나뉘어 초기화된다.
  
	현재 볼륨 이름 / 다음 볼륨 이름(현재 0) / 주석
	나중에 다음 볼륨이 생겨서 이름이 정해지면 '다음 볼륨 이름' 이 다시 수정된다.

	if (영구 타입이면) 볼륨 헤더에 {
		log_append_dboutside_redo() db밖에서 redo된 데이터 로그들을 이어 붙인다
		log_append_redo_data() db내에서 redo된 데이터 로그들을 이어 붙인다. // is it neccessary?
	}

	disk_stab_init(thread_p, vhdr) // stab의 초기화

	if (영구 타입이면서 첫 볼륨이 아니라면) {
		이전 볼륨과 링크 시킨다.
	}

	if (영구 타입이면) {
		log_append_redo_data() db내에서 redo된 데이터 정보를 로그에 이어 붙인다.
	}

	if (임시 목적이라면) {
		pgbuf_flush_all() page buffer를 flush한다.
		dwb_flush_force() dwb를 flush 한다.
		
		for (볼륨 헤더의 모든 page_id마다)
			pgptr = pgbuf_fix() 페이지 포인터를 불러와서
			pgbuf_set_lsa_as_temporary (pgptr)	lsa를 임시 목적으로 설정한다.
	if (영구 타입이라면) {
		pgbuf_invalidate_all(): 모든 더티 페이지를 flush하고 page buffer pool에서 무효화 시킨다. 볼륨의 복구 정보를 리셋시키기 위함.
		fileio_reset_volume(vdes, ...): OS파일에 직접 접근해서 recovery information을 리셋한다.
	}
	
	disk_verify_volume_header (addr.pgptr): vhdr의 내용이 실제 페이지에 반영되었는지 확인
	pgbuf_flush_all (): 페이지 버퍼를 모두 flush한다.
	fileio_synchronize(): 볼륨의 상태와 디스크의 상태를 일치시킨다.

	return;

}
```

		

- disk_stab_init() - *initialize new sector table*

```jsx
disk_stab_init(volume_header) {
	nsects_sys = (볼륨 헤더의 마지막 페이지 번호 + 1) / 섹터 내 한 페이지의 크기
	즉, 볼륨 헤더 내 섹터 수

	for (page_id = 볼륨 헤더에 설정된 stab 첫번째 페이지;
				page_id < 설정된 stab 첫번째 페이지 + 설정된 페이지 수; page_id++) {

		page_stab = pgbuf_fix(volume_id, page_id): 페이지 아이디를 통해 버퍼 내의 stab 페이지에 접근
		
		pgbuf_set_page_ptype (page_stab, 페이지의 타입)
	
		if (임시 목적이라면) {
			pgbuf_set_lsa_as_temporary (page_stab): lsa를 임시 목적으로 설정
		}
	
		memset (page_stab, 0, DB_PAGESIZE);
	
		* 커서는 volume_header, secter_id, page_id, offset_to_unit, offset_to_bit를 가진 구조체
    
		if (nsects_sys > 0)
			disk_stab_cursor_set_at_sectid(&start_cursor,
					(pageid - stab_first_page) * 페이지 당 비트 카운트)
			: start_cursor에 이번 page의 volume_header, secter_id, page_id, offset_to_unit, offset_to_bit를 설정.
	    : 이때 비트 수를 구할 때 page bit count를 곱하였으므로 offset은 0이 된다.

		if (현재 page_id가 마지막 page_id라면) {
			end_cursor = disk_stab_cursor_set_at_end()
			end_cursor를 마지막 비트에다 맞춘다.
      
		} else {
			disk_stab_cursor_set_at_sectid(&end_cursor,
				(pageid - stab_first_page + 1) * 페이지 당 비트 카운트)
			: 다음 페이지의 시작에 end cursor를 맞춘다.

		disk_stab_iterate_units (volheader, &start_cursor, &end_cursor,
						disk_stab_set_bits_contiguous, &nsect_copy);
		: start_cursor부터 end_cursor까지 disk_stab_set_bits_contiguous를 적용.
		: disk_stab_set_bits_contiguous: 범위 내의 모든 비트를 1로 채운다.
		}
	
		if (영구 목적 볼륨이라면) {
			log_append_redo_data2(): redo한 결과를 로그에 이어붙임.
		}
		if (로그가 재시작 되었으면) {
			/* page buffer will invalidated and pages will not be flushed. */ ??
      
			pgbuf_set_dirty(page_stab, DONT_FREE);
			: page_stab을 dirty로 설정하고 free하지 않는다.
		  pgbuf_flush(page_stab, FREE);
			: page_stab를 flush하고 free한다.
      
		} else {
			pgbuf_set_dirty_and_free(page_stab);
			
		
	
```
