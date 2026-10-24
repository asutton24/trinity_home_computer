lda #$05
ldb #$03
sec
clc
adc b
sta $0010
hlt