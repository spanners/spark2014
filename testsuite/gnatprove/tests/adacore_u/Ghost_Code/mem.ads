package Mem with
  SPARK_Mode,
  Abstract_State => State
is
   procedure Alloc with
     Pre  => Free_Memory > 0,
     Post => Free_Memory < Free_Memory'Old;

   function Free_Memory return Natural with Ghost;

end Mem;
