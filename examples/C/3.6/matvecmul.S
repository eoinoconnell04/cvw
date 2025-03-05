.global matvecmul
matvecmul: # Base addresses of A, x, y in a0, a1, a2; m,n in a3, a4
  # I,j,sum in s0, s1, s2
  addi sp, sp, -12 		# save s0-s2 on the stack
  sw s0, 0(sp)
  sw s1, 4(sp)
  sw s2, 8(sp)
  li s0, 0 			# i = 0
fori: 
  bge s0, a3, donei		# done with I loop if I >= m
  li s2, 0 			# sum = 0
  li s1, 0 			# j = 0
forj: 
  bge s1, a4, donej		# done with j loop if j >= n
  mul t0, s0, a4 		# I * n
  add t0, t0, s1 		# I * n + j
  slli t0, t0, 2 		# multiply by 4 to convert from ints to bytes
  add t0, a0, t0 		# &A[i*n+j]
  lw t0, 0(t0) 		# A[i*n+j]
  slli t1, s1, 2 		# multiply by 4 to convert j from ints to bytes
  addi t1, a1, t1 		# &x[j]
  lw t1, 0(t1) 		# x[j]
  mul t0, t0, t1 		# A[i*n+j] * x[j]
  add s2, s2, t0 		# sum = sum + A[i*n+j] * x[j]
  addi s1, s1, 1 		# j = j + 1
  j forj
donej: 
  slli t0, s0, 2 		# multiply by 4 to convert I from ints to bytes
  add t0, a2, t0 		# &y[i]
  sw s2, 0(t0) 		# y[i] = sum
  addi s0, s0, 1 		# i = i + 1
  j fori
donei:
  lw s2, 8(sp) 		# restore s0-s2 from stack
  lw s1, 4(sp)
  lw s0, 0(sp)
  addi sp, sp, 12
  ret				# return from matvecmul

