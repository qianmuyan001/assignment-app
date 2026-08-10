from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from .. import models, schemas
from ..database import get_db


router = APIRouter(prefix="/assignments", tags=["assignments"])


def get_assignment_or_404(db: Session, assignment_id: int) -> models.Assignment:
    assignment = db.get(models.Assignment, assignment_id)
    if assignment is None:
        raise HTTPException(status_code=404, detail="Assignment not found")
    return assignment


@router.post(
    "",
    response_model=schemas.AssignmentRead,
    status_code=status.HTTP_201_CREATED,
)
def create_assignment(
    assignment_in: schemas.AssignmentCreate,
    db: Session = Depends(get_db),
) -> models.Assignment:
    assignment = models.Assignment(**assignment_in.model_dump())
    db.add(assignment)
    db.commit()
    db.refresh(assignment)
    return assignment


@router.get("", response_model=list[schemas.AssignmentRead])
def list_assignments(db: Session = Depends(get_db)) -> list[models.Assignment]:
    statement = select(models.Assignment).order_by(
        models.Assignment.due_date.is_(None),
        models.Assignment.due_date.asc(),
        models.Assignment.created_at.desc(),
    )
    return list(db.scalars(statement).all())


@router.get("/search", response_model=list[schemas.AssignmentRead])
def search_assignments(
    query: str,
    db: Session = Depends(get_db),
) -> list[models.Assignment]:
    cleaned_query = query.strip()
    if not cleaned_query:
        return []

    pattern = f"%{cleaned_query}%"
    statement = (
        select(models.Assignment)
        .where(
            or_(
                models.Assignment.course_name.ilike(pattern),
                models.Assignment.title.ilike(pattern),
                models.Assignment.description.ilike(pattern),
                models.Assignment.link.ilike(pattern),
                models.Assignment.source_name.ilike(pattern),
                models.Assignment.source_file.ilike(pattern),
                models.Assignment.source_url.ilike(pattern),
            )
        )
        .order_by(models.Assignment.due_date.is_(None), models.Assignment.due_date.asc())
    )
    return list(db.scalars(statement).all())


@router.get("/{assignment_id}", response_model=schemas.AssignmentRead)
def get_assignment(
    assignment_id: int,
    db: Session = Depends(get_db),
) -> models.Assignment:
    return get_assignment_or_404(db, assignment_id)


@router.put("/{assignment_id}", response_model=schemas.AssignmentRead)
@router.patch("/{assignment_id}", response_model=schemas.AssignmentRead)
def update_assignment(
    assignment_id: int,
    assignment_in: schemas.AssignmentUpdate,
    db: Session = Depends(get_db),
) -> models.Assignment:
    assignment = get_assignment_or_404(db, assignment_id)
    updates = assignment_in.model_dump(exclude_unset=True)

    for field_name, value in updates.items():
        setattr(assignment, field_name, value)

    db.commit()
    db.refresh(assignment)
    return assignment


@router.delete("/{assignment_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_assignment(
    assignment_id: int,
    db: Session = Depends(get_db),
) -> Response:
    assignment = get_assignment_or_404(db, assignment_id)
    db.delete(assignment)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.patch("/{assignment_id}/status", response_model=schemas.AssignmentRead)
def update_assignment_status(
    assignment_id: int,
    status_in: schemas.AssignmentStatusUpdate,
    db: Session = Depends(get_db),
) -> models.Assignment:
    assignment = get_assignment_or_404(db, assignment_id)
    assignment.status = status_in.status
    db.commit()
    db.refresh(assignment)
    return assignment
