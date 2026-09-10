// tidycloset.ash  --  bare = preview (moves nothing), "tidycloset go" = live (empties the closet and runs tidy).
import "tidy_common.ash";
void main(string... args) { tidy_dispatch("closet", args); }
