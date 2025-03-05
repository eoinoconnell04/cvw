# fir.S
# Eoin O'Connell Feb 7 2025

.section .text
.global fir

fir:
    # a0 = x[], a1 = c[], a2 = y[], a3 = n, a4 = m
    # Prologue: Save registers if needed
    addi sp, sp, -16
    sw s1, 0(sp)  # Save s1 (loop index j)
    sw s2, 4(sp)  # Save s2 (loop index i)
    sw s3, 8(sp)  # Save temporary accumulators
    sw s4, 12(sp) # Save additional temporary register

    li s1, 0        # j = 0
    sub s4, a3, a4  # n - m + 1 (loop limit)
    addi s4, s4, 1

outer_loop_j:
    bge s1, s4, end # if j >= n-m+1, exit

    li s3, 0        # y[j] = 0
    li s2, 0        # i = 0

next_j:
    # Store result y[j]
    slli t0, s1, 2
    add t0, a2, t0
    sw s3, 0(t0)

    addi s1, s1, 1    # j++
    j outer_loop_j

inner_loop_i:
    bge s2, a4, next_j # if i >= m, go to next j

    # Load x[j - i + (m - 1)]
    sub t0, s1, s2
    add t0, t0, a4
    addi t0, t0, -1
    slli t0, t0, 2    # Multiply index by 4 (word size)
    add t0, a0, t0
    lw t1, 0(t0)      # Load x[j - i + (m - 1)]

    # Load c[i]
    slli t2, s2, 2    # Multiply index by 4
    add t2, a1, t2
    lw t2, 0(t2)      # Load c[i]

    # Multiply c[i] * x[j - i + (m - 1)]
    mul t3, t1, t2
    srai t3, t3, 31   # Shift right for Q1.31 fixed point format

    # Add to y[j]
    add s3, s3, t3

    addi s2, s2, 1    # i++
    j inner_loop_i

end:
    # Restore saved registers
    lw s1, 0(sp)
    lw s2, 4(sp)
    lw s3, 8(sp)
    lw s4, 12(sp)
    addi sp, sp, 16
    ret

