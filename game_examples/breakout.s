lds #$7FFF
lda #$00
sta $9000
lda #$00
sta $0010
lda #$80
sta $0011
ldi #$00
clear_loop: lda #$0F
sta ($0010),i
inc i
lda #$20
sta ($0010),i
inc i
jne clear_loop
inc $0011
lda $0011
cmp #$89
jne clear_loop
ldi #$00
clear_last: lda #$0F
sta $8900,i
inc i
lda #$20
sta $8900,i
inc i
tia
cmp #$60
jne clear_last
lda #$14
sta $0020
jsr draw_paddle
loop: lda $9001
wait_clock: cmp $9001
jeq wait_clock
lda $9005
bit 2
jcs move_left
bit 1
jcs move_right
jmp loop
move_left: lda $0020
cmp #$00
jeq loop
jsr clear_paddle
dec $0020
jsr draw_paddle
jmp loop
move_right: lda $0020
cmp #$27
jeq loop
jsr clear_paddle
inc $0020
jsr draw_paddle
jmp loop
draw_paddle: lda $0020
asl a
tai
lda #$0F
sta $8780,i
lda #$5F
sta $8781,i
ret
clear_paddle: lda $0020
asl a
tai
lda #$0F
sta $8780,i
lda #$20
sta $8781,i
ret