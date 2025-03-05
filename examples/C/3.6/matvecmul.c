#include "matvecmul.S"

void main(void) {
  int A[6] = {1, 2, 3, 4, 5, 6};
  int x[3] = {7, 8, 9};
  int y[2];
  
  matvecmul(A, x, y, 2, 3);
  }

