from fastapi import APIRouter, HTTPException, Response, status

from . import schemas, storage


router = APIRouter(prefix="/assignments", tags=["assignments"])


@router.get("", response_model=list[schemas.AssignmentRead])
def get_assignments() -> list[schemas.AssignmentRead]:
    return storage.get_all_assignments()


@router.get("/{assignment_id}", response_model=schemas.AssignmentRead)
def get_assignment(assignment_id: int) -> schemas.AssignmentRead:
    assignment = storage.get_assignment_by_id(assignment_id)

    if assignment is None:
        raise HTTPException(status_code=404, detail="Assignment not found")

    return assignment


@router.post(
    "",
    response_model=schemas.AssignmentRead,
    status_code=status.HTTP_201_CREATED,
)
def create_assignment(
    assignment_create: schemas.AssignmentCreate,
) -> schemas.AssignmentRead:
    return storage.create_assignment(assignment_create)


@router.patch("/{assignment_id}", response_model=schemas.AssignmentRead)
def update_assignment(
    assignment_id: int,
    assignment_update: schemas.AssignmentUpdate,
) -> schemas.AssignmentRead:
    assignment = storage.update_assignment(assignment_id, assignment_update)

    if assignment is None:
        raise HTTPException(status_code=404, detail="Assignment not found")

    return assignment


@router.patch("/{assignment_id}/status", response_model=schemas.AssignmentRead)
def update_assignment_status(
    assignment_id: int,
    status_update: schemas.AssignmentStatusUpdate,
) -> schemas.AssignmentRead:
    assignment = storage.update_assignment_status(assignment_id, status_update)

    if assignment is None:
        raise HTTPException(status_code=404, detail="Assignment not found")

    return assignment


@router.delete("/{assignment_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_assignment(assignment_id: int) -> Response:
    assignment = storage.delete_assignment(assignment_id)

    if assignment is None:
        raise HTTPException(status_code=404, detail="Assignment not found")

    return Response(status_code=status.HTTP_204_NO_CONTENT)
